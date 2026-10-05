# Azure Reference

## User Prerequisites (First-Time Setup)

The user needs **Owner** or **User Access Administrator + Contributor** role on the Azure subscription, plus **Application Administrator** in Entra ID (formerly Azure AD) to create service principals.

## Team Member Prerequisites (Adding to Existing Setup)

The user needs **Application Administrator** (or **Cloud Application Administrator**) in Entra ID to add a client secret to the existing app registration. No subscription-level role is needed since roles are already assigned to the service principal.

## Key Limits

Each team member gets their own client secret on the same application/service principal. The number is **not unlimited**: Microsoft caps the entries across an application's manifest collections, `passwordCredentials` included, at a shared total ([manifest limits](https://learn.microsoft.com/en-us/entra/identity-platform/reference-app-manifest#manifest-limits)), so secrets left behind by departed members and rotations count against it. Add Team Member lists the existing secrets first; remove expired or departed members' secrets (see "Secret Management") before adding more.

## CLI Installation

The Claude Code on the Web sandbox may not have `az` pre-installed. Use this script to install it:

```bash
if ! command -v az &> /dev/null; then
  for dir in /usr/bin /usr/local/bin /home/user/bin; do
    if [ -x "$dir/az" ]; then export PATH="$dir:$PATH"; break; fi
  done
fi
if ! command -v az &> /dev/null; then
  if ! curl -sSL https://aka.ms/InstallAzureCLIDeb | sudo bash; then
    echo "WARNING: Azure CLI install failed."
  fi
fi
```

### SessionStart Hook

After setup completes, create a SessionStart hook that installs the CLI **and** authenticates automatically. Create `.claude/hooks/cloud-auth.sh`:

```bash
#!/bin/bash
set -e

# Claude Code on the Web only: each session is its own container. Locally,
# `az login` writes the identity into the OS user's shared Azure CLI cache, so
# concurrent sessions would overwrite each other's principal and subscription;
# local users keep their own `az login`.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then exit 0; fi

# --- Auto-authenticate if credentials exist ---
CONFIG=".cloud-config.json"
if [ ! -f "$CONFIG" ]; then exit 0; fi

PROVIDER=$(jq -r .provider "$CONFIG" 2>/dev/null) || exit 0
if [ "$PROVIDER" != "azure" ]; then exit 0; fi

USER_EMAIL=$(git config user.email 2>/dev/null || true)
ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
if [ -z "$USER_EMAIL" ] || [ ! -f "$ENC_FILE" ]; then exit 0; fi

KEY="${AZURE_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}"
if [ -z "$KEY" ]; then exit 0; fi

# --- Per-file credential age, as in the Authenticate workflow ---
COMMIT_TS=$(git log --follow --diff-filter=AM -1 --format=%ct -- "$ENC_FILE" 2>/dev/null || true)
if [ -z "$COMMIT_TS" ]; then
  COMMIT_TS=$(date -d "$(jq -r '.created_at // empty' "$CONFIG")" +%s 2>/dev/null || true)
fi
if [ -n "$COMMIT_TS" ] && [ "$(( ( $(date +%s) - COMMIT_TS ) / 86400 ))" -gt 180 ]; then
  echo "NOTE: Azure credentials in $ENC_FILE are over 180 days old — consider rotating (see Credential Rotation)."
fi

# --- Install az CLI if missing ---
if ! command -v az &> /dev/null; then
  for dir in /usr/bin /usr/local/bin /home/user/bin; do
    if [ -x "$dir/az" ]; then export PATH="$dir:$PATH"; break; fi
  done
fi
if ! command -v az &> /dev/null; then
  if ! curl -sSL https://aka.ms/InstallAzureCLIDeb | sudo bash; then
    echo "WARNING: Azure CLI install failed — skipping Azure auth."
    exit 0
  fi
fi

# --- Decrypt credentials (restrictive permissions + guaranteed cleanup) ---
trap 'rm -f /tmp/credentials.json' EXIT
if ! (umask 077 && echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null); then
  echo "WARNING: Failed to decrypt credentials — check AZURE_CREDENTIALS_KEY or .enc file integrity."
  exit 0
fi

if ! az login --service-principal \
  --username "$(jq -r .appId /tmp/credentials.json)" \
  --password "$(jq -r .password /tmp/credentials.json)" \
  --tenant "$(jq -r .tenant /tmp/credentials.json)" 2>/dev/null; then
  echo "WARNING: az login failed — credentials may be revoked."
  exit 0
fi
# Without the configured subscription, commands would silently run against
# whatever default az login picked: treat a failed switch as a failed login.
if ! az account set --subscription "$(jq -r .project_id "$CONFIG" 2>/dev/null)" 2>/dev/null; then
  echo "WARNING: could not select the configured Azure subscription — logging out; check project_id and the service principal's access."
  az logout 2>/dev/null || true
  exit 0
fi

# Persist the resolved az CLI path for the rest of the session. Without this,
# later shells can have a valid cached Azure login but still hit
# "az: command not found" (the AWS/GCP hooks persist their CLI paths the same way).
if [ -n "$CLAUDE_ENV_FILE" ] && command -v az &>/dev/null; then
  AZ_BIN="$(dirname "$(command -v az)")"
  grep -qxF "export PATH=\"$AZ_BIN:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "export PATH=\"$AZ_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

echo "Azure credentials activated for $USER_EMAIL"
```

Then add to `.claude/settings.json` (create the file and directories if needed):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/cloud-auth.sh\"",
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

If `.claude/settings.json` already exists, merge the `SessionStart` hook into the existing `hooks` object. Commit both `.claude/hooks/cloud-auth.sh` and `.claude/settings.json`.

## Bootstrap Token Command

Tell the user to run locally:

```bash
az login
az account set --subscription SUBSCRIPTION_ID

# Print both tokens so they can be pasted back into the session:
# ARM token — for resource management and role assignments
echo "ARM_TOKEN=$(az account get-access-token --query accessToken -o tsv)"
# Graph token — for app registrations, service principals, client secrets
echo "GRAPH_TOKEN=$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv)"
```

The user pastes both lines; set `ARM_TOKEN` and `GRAPH_TOKEN` from them in the session.

Both tokens are valid for ~1 hour. **Important:** ARM tokens are NOT valid for Microsoft Graph API calls, and vice versa. Use the correct token for each endpoint.

## API Approach

Use the Azure CLI (`az`) if available. Otherwise, use REST API calls with the appropriate token:
- **ARM operations** (role assignments, subscriptions): `curl -H "Authorization: Bearer $ARM_TOKEN"` against `https://management.azure.com`
- **Graph operations** (app registrations, service principals, secrets): `curl -H "Authorization: Bearer $GRAPH_TOKEN"` against `https://graph.microsoft.com`

## Create Service Principal

```bash
# A fixed display name such as "claude-agent" can make create-for-rbac modify an
# existing app with that name. Derive a repo-specific name, refuse to proceed if
# it is already taken, and ask the user to approve a different name instead.
# Name: a sanitized repo slug (letters, digits, '-') plus a random per-run
# suffix. Sanitizing keeps the name safe inside JSON and OData strings; the
# suffix makes concurrent setups pick different names, so neither can modify
# the other's application (create-for-rbac reuses objects that share a name).
REPO_SLUG=$(printf '%s' "$(basename "$(git rev-parse --show-toplevel)")" | tr -c 'A-Za-z0-9-' '-' | cut -c1-40)
SP_NAME="claude-agent-${REPO_SLUG}-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
echo "Service principal name for this setup: $SP_NAME (keep it until setup finishes)"
# create-for-rbac can modify an existing application OR service principal with
# this display name, so both collections must be empty.
# A failed lookup (expired login, no directory read access, API error) is not
# "no collision": stop unless both lookups succeed AND both come back empty.
SP_HITS=$(az ad sp list --display-name "$SP_NAME" --query '[].appId' -o tsv) \
  || { echo "ERROR: service-principal lookup failed; cannot check for a name collision."; exit 1; }
APP_HITS=$(az ad app list --display-name "$SP_NAME" --query '[].appId' -o tsv) \
  || { echo "ERROR: application lookup failed; cannot check for a name collision."; exit 1; }
if [ -n "$SP_HITS" ] || [ -n "$APP_HITS" ]; then
  echo "ERROR: an application or service principal named $SP_NAME already exists; choose another name with the user."
  exit 1
fi

# Creating without a role assignment is the default (--skip-assignment is obsolete).
# The output holds the new client secret: write it private (0600) from the start.
(umask 077 && az ad sp create-for-rbac --name "$SP_NAME" > credentials.json)
```

This returns `appId`, `password` (client secret), and `tenant`. The credentials file is already in the right format.

If `az` is not available, use the Microsoft Graph API (requires `$GRAPH_TOKEN`):

```bash
# Step 0: Collect the tenant ID BEFORE creating anything. This REST path is used
# when `az` is unavailable, so ask the user for it (Entra ID > Overview >
# Tenant ID) and export TENANT_ID. Never persist a placeholder.
[ -n "$TENANT_ID" ] || { echo "ERROR: ask the user for their Azure tenant ID and set TENANT_ID first."; exit 1; }

# Every Graph call fails on HTTP errors (--fail) and its required fields are
# checked, so an error body is never read as a result. If any later step fails,
# the trap deletes the half-created application (which removes its service
# principal and secrets with it) and the local response files.
set -e
APP_OBJECT_ID=""
cleanup_failed_setup() {
  if [ -n "$APP_OBJECT_ID" ]; then
    curl -sS --fail -X DELETE "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
      -H "Authorization: Bearer $GRAPH_TOKEN" >/dev/null \
      || echo "WARNING: could not delete application $APP_OBJECT_ID; remove it in the portal."
  fi
  rm -f app.json sp.json secret.json credentials.json
}
trap 'cleanup_failed_setup' ERR

# Step 1: Create application (same sanitized, per-run name as the CLI path above)
# Name: a sanitized repo slug (letters, digits, '-') plus a random per-run
# suffix. Sanitizing keeps the name safe inside JSON and OData strings; the
# suffix makes concurrent setups pick different names, so neither can modify
# the other's application (create-for-rbac reuses objects that share a name).
REPO_SLUG=$(printf '%s' "$(basename "$(git rev-parse --show-toplevel)")" | tr -c 'A-Za-z0-9-' '-' | cut -c1-40)
SP_NAME="claude-agent-${REPO_SLUG}-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
echo "Service principal name for this setup: $SP_NAME (keep it until setup finishes)"
EXISTING=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
  --data-urlencode "\$filter=displayName eq '$SP_NAME'" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value | length')
[ "$EXISTING" = "0" ] || { echo "ERROR: an application named $SP_NAME already exists (or the lookup failed); choose another name with the user."; exit 1; }
(umask 077 && curl -sS --fail -X POST "https://graph.microsoft.com/v1.0/applications" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"displayName\": \"$SP_NAME\"}" > app.json)
APP_ID=$(jq -r '.appId // empty' app.json)
APP_OBJECT_ID=$(jq -r '.id // empty' app.json)
[ -n "$APP_ID" ] && [ -n "$APP_OBJECT_ID" ] || { echo "ERROR: application response lacks appId/id."; false; }

# Step 2: Create service principal
(umask 077 && curl -sS --fail -X POST "https://graph.microsoft.com/v1.0/servicePrincipals" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"appId\": \"$APP_ID\"}" > sp.json)
[ -n "$(jq -r '.id // empty' sp.json)" ] || { echo "ERROR: service principal response lacks id."; false; }

# Step 3: Add client secret
(umask 077 && curl -sS --fail -X POST "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID/addPassword" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"passwordCredential": {"displayName": "claude-code"}}' > secret.json)
SECRET=$(jq -r '.secretText // empty' secret.json)
[ -n "$SECRET" ] || { echo "ERROR: addPassword response lacks secretText."; false; }

# Step 4: Assemble credentials
(umask 077 && jq -n \
  --arg appId "$APP_ID" \
  --arg password "$SECRET" \
  --arg tenant "$TENANT_ID" \
  '{appId: $appId, password: $password, tenant: $tenant}' > credentials.json)

trap - ERR
rm -f app.json sp.json secret.json
echo "Created application $SP_NAME (object id $APP_OBJECT_ID). Keep APP_OBJECT_ID until setup finishes."
```

The tenant ID is collected first, before any Graph call creates anything, so a missing tenant never leaves a half-created application or a live secret on disk.

The trap above only covers this block: the agent may run each snippet in its own shell, where a trap cannot follow. Role grants, encryption, and the commit still come after it, so **if any later setup step fails, run the rollback below before retrying**. Otherwise the application and its live client secret stay behind, possibly with some roles already granted, and the name-collision check blocks a retry with the same name.

### Rollback a Failed Setup

```bash
# Delete the application created above (this removes its service principal,
# client secrets, and role assignments' principal) and the local plaintext.
# Use the exact name or object id this setup printed: the name has a random
# per-run suffix, so it cannot be re-derived from the repo.
[ -n "$APP_OBJECT_ID" ] || [ -n "$SP_NAME" ] || { echo "ERROR: set APP_OBJECT_ID or SP_NAME from the failed setup's output."; exit 1; }
if [ -z "$APP_OBJECT_ID" ]; then
  APP_OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
    --data-urlencode "\$filter=displayName eq '$SP_NAME'" \
    -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
fi
if [ -n "$APP_OBJECT_ID" ]; then
  curl -sS --fail -X DELETE "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
    -H "Authorization: Bearer $GRAPH_TOKEN" \
    && echo "Deleted application $SP_NAME." \
    || echo "WARNING: could not delete application $APP_OBJECT_ID; remove it in the portal."
fi
rm -f credentials.json app.json sp.json secret.json
```

With the CLI path, `az ad app delete --id "$(jq -r .appId credentials.json)"` does the same; run it before removing `credentials.json`. Role assignments left on the deleted principal no longer grant anything and can be removed with `az role assignment delete --assignee <appId>`.

## Grant Roles

Roles are assigned to the **service principal**, so they apply to all team members automatically. No per-user role assignment needed.

```bash
# APP_ID is the service principal's appId. During first-time setup it comes from
# the credentials you just created; in later sessions read it from config.
APP_ID="${APP_ID:-$(jq -r '.appId // empty' credentials.json 2>/dev/null)}"
# Provider-aware fallback: in multi-provider configs the app id is in providers[]
APP_ID="${APP_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else .service_account end) // empty' .cloud-config.json 2>/dev/null)}"
[ -n "$APP_ID" ] || { echo "ERROR: could not resolve the app id from credentials.json or .cloud-config.json."; exit 1; }

# During first-time setup .cloud-config.json does not exist yet: use the
# subscription ID gathered in Step 2, and read config only in later sessions.
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .project_id) else .project_id end) // empty' .cloud-config.json 2>/dev/null)}"
[ -n "$SUBSCRIPTION_ID" ] || { echo "ERROR: set SUBSCRIPTION_ID to the subscription gathered in Step 2."; exit 1; }
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "ROLE_NAME" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

Or via REST API (requires `$ARM_TOKEN` and `$GRAPH_TOKEN`):

```bash
# Resolve the service principal's object id from its appId before assigning a
# role. The role assignment's principalId must be this SP object id, not the
# appId, or the assignment is created against an empty/incorrect principal.
APP_ID="${APP_ID:-$(jq -r '.appId // empty' credentials.json 2>/dev/null)}"
# Provider-aware fallback: in multi-provider configs the app id is in providers[]
APP_ID="${APP_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else .service_account end) // empty' .cloud-config.json 2>/dev/null)}"
[ -n "$APP_ID" ] || { echo "ERROR: could not resolve the app id from credentials.json or .cloud-config.json."; exit 1; }
# During first-time setup .cloud-config.json does not exist yet: use the
# subscription ID gathered in Step 2, and read config only in later sessions.
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .project_id) else .project_id end) // empty' .cloud-config.json 2>/dev/null)}"
[ -n "$SUBSCRIPTION_ID" ] || { echo "ERROR: set SUBSCRIPTION_ID to the subscription gathered in Step 2."; exit 1; }
SP_OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/servicePrincipals" \
  --data-urlencode "\$filter=appId eq '$APP_ID'" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
[ -n "$SP_OBJECT_ID" ] || { echo "ERROR: service principal for $APP_ID not found. During setup, run Rollback a Failed Setup."; exit 1; }

# URL-encode the query: role names contain spaces (e.g. "Storage Blob Data
# Contributor"), which curl rejects if substituted raw into the URL. Let curl
# encode the params via -G/--data-urlencode.
ROLE_DEFINITION_ID=$(curl -sS --fail -G \
  "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions" \
  --data-urlencode "api-version=2022-04-01" \
  --data-urlencode "\$filter=roleName eq 'ROLE_NAME'" \
  -H "Authorization: Bearer $ARM_TOKEN" | jq -r '.value[0].id // empty')
[ -n "$ROLE_DEFINITION_ID" ] || { echo "ERROR: role 'ROLE_NAME' not found in subscription $SUBSCRIPTION_ID. During setup, run Rollback a Failed Setup."; exit 1; }

# The assignment name must be a new GUID. uuidgen is often missing from minimal
# images, so fall back to the kernel's generator, then Python.
ASSIGNMENT_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null \
  || python3 -c 'import uuid; print(uuid.uuid4())')
[ -n "$ASSIGNMENT_ID" ] || { echo "ERROR: could not generate a GUID for the role assignment."; exit 1; }

curl -sS --fail -X PUT \
  "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleAssignments/$ASSIGNMENT_ID?api-version=2022-04-01" \
  -H "Authorization: Bearer $ARM_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"properties\": {
      \"roleDefinitionId\": \"$ROLE_DEFINITION_ID\",
      \"principalId\": \"$SP_OBJECT_ID\",
      \"principalType\": \"ServicePrincipal\"
    }
  }"
```

Prefer scoping roles to specific resource groups rather than the entire subscription.

## Add Client Secret for Existing App (Team Members)

When a new team member joins, create a new client secret for the existing app. Read the `appId` from `.cloud-config.json` (stored as `service_account`).

```bash
# Resolve and validate everything BEFORE creating a secret, so a bad config
# never leaves a live secret behind (provider-aware: in multi-provider mode
# these live in the matching providers[] entry).
azcfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"azure\") | .$1) else .$1 end) // empty" .cloud-config.json 2>/dev/null; }
APP_ID=$(azcfg service_account)
TENANT_ID="${TENANT_ID:-$(azcfg tenant)}"
[ -n "$APP_ID" ] || { echo "ERROR: no Azure service_account (appId) in .cloud-config.json."; exit 1; }
[ -n "$TENANT_ID" ] || { echo "ERROR: Azure tenant ID not found in .cloud-config.json — ask the user and set TENANT_ID."; exit 1; }
OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
  --data-urlencode "\$filter=appId eq '$APP_ID'" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
[ -n "$OBJECT_ID" ] || { echo "ERROR: could not resolve the application for appId $APP_ID."; exit 1; }

# Existing secrets count against the application's credential limit (see Key Limits)
curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '"existing secrets: \(.passwordCredentials | length)"'

USER_EMAIL=$(git config user.email)

# Add a new client secret labeled with the user's email; fail on HTTP errors
(umask 077 && curl -sS --fail -X POST "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/addPassword" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"passwordCredential\": {\"displayName\": \"claude-code-${USER_EMAIL}\"}}" \
  > secret.json) || { rm -f secret.json; echo "ERROR: addPassword failed; no secret was created."; exit 1; }
SECRET=$(jq -r '.secretText // empty' secret.json)
[ -n "$SECRET" ] || { rm -f secret.json; echo "ERROR: addPassword response has no secretText."; exit 1; }

# Assemble credentials (appId and tenant are the same for all team members)
(umask 077 && jq -n \
  --arg appId "$APP_ID" \
  --arg password "$SECRET" \
  --arg tenant "$TENANT_ID" \
  '{appId: $appId, password: $password, tenant: $tenant}' > credentials.json)

rm -f secret.json
```

**Note:** The `.cloud-config.json` for Azure should also store `tenant` alongside the other fields.

## Secret Management

Resolve the application first (later sessions have no `OBJECT_ID` in scope), then list its client secrets (requires `$GRAPH_TOKEN`):

```bash
APP_ID=$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else .service_account end) // empty' .cloud-config.json)
OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
  --data-urlencode "\$filter=appId eq '$APP_ID'" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
[ -n "$OBJECT_ID" ] || { echo "ERROR: could not resolve the application for appId '$APP_ID'."; exit 1; }

curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq '.passwordCredentials[] | {displayName, keyId, endDateTime}'
```

Remove a specific client secret (if a team member leaves), with `OBJECT_ID` resolved as above. Delete their `.cloud-credentials.<email>.enc` file only after Graph confirms the removal (HTTP 204), so the repo never drops the record of a secret that is still live:

```bash
KEY_ID="KEY_ID_TO_REMOVE"
[ -n "$OBJECT_ID" ] && [ -n "$KEY_ID" ] || { echo "ERROR: resolve OBJECT_ID and set KEY_ID first."; exit 1; }
STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/removePassword" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"keyId\": \"$KEY_ID\"}")
if [ "$STATUS" = "204" ]; then
  echo "Secret $KEY_ID removed; now delete the member's .cloud-credentials.<email>.enc file."
else
  echo "ERROR: removePassword returned HTTP $STATUS; the secret may still be active. Keep the .enc file and retry."
  exit 1
fi
```

## Activate (Subsequent Sessions)

After decrypting credentials to `/tmp/credentials.json`:

```bash
az login --service-principal \
  --username "$(jq -r .appId /tmp/credentials.json)" \
  --password "$(jq -r .password /tmp/credentials.json)" \
  --tenant "$(jq -r .tenant /tmp/credentials.json)"

# Provider-aware subscription: in multi-provider repos the subscription id is in
# the matching providers[] entry, not at top-level .project_id.
az account set --subscription "$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .project_id) else .project_id end)' .cloud-config.json)" \
  || { az logout; rm -f /tmp/credentials.json; echo "ERROR: could not select the configured subscription."; exit 1; }

rm -f /tmp/credentials.json
```

## Verify (Smoke Test)

After activating credentials, run this lightweight check to confirm they work:

```bash
az account show --query "{name:name, id:id}" -o json
```

If this fails, the credentials may be expired or the client secret may have been revoked. Re-run the **Authenticate** flow or ask the user to check the service principal.

## Common Roles Reference

| Need | Role |
|------|------|
| Deploy Functions | `Website Contributor` |
| Manage Storage | `Storage Blob Data Contributor` |
| Manage Cosmos DB | `Cosmos DB Operator` |
| Deploy Container Apps | `Contributor` (scoped to resource group) |
| Manage Service Bus | `Azure Service Bus Data Owner` |
| Read logs | `Log Analytics Reader` |
| Manage Key Vault secrets | `Key Vault Secrets Officer` |
| Deploy via ARM/Bicep | `Contributor` (scoped to resource group) |
| Manage SQL databases | `SQL DB Contributor` |

**Prefer scoping roles to specific resource groups over subscription-wide assignments.**
