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
# Log out an earlier activation in this container (az keeps its login in a
# persistent token cache) whenever this run exits without renewing it
trap '[ "${AZ_ACTIVATED:-}" = 1 ] || { command -v az >/dev/null 2>&1 && az logout >/dev/null 2>&1 || true; }; rm -f /tmp/credentials.json' EXIT

# Hooks run in the session's current directory, which may be a subdirectory.
# Entered only after the cleanup above is armed: a missing or unreadable
# project directory must still clear an earlier activation
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || { echo "WARNING: cannot enter ${CLAUDE_PROJECT_DIR:-.}; repository cloud auth is cleared for this session."; exit 0; }

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
# (the EXIT trap set above also removes /tmp/credentials.json)
if ! (umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null); then
  echo "WARNING: Failed to decrypt credentials — check AZURE_CREDENTIALS_KEY or .enc file integrity."
  exit 0
fi

# Use the credential only if it is for the configured application: a stale or
# copied file could hold another service principal with access to this
# subscription, and az account set would not notice
APP_CFG=$(jq -r '.service_account // empty' "$CONFIG" 2>/dev/null)
if [ -z "$APP_CFG" ] || [ "$(jq -r '.appId // empty' /tmp/credentials.json)" != "$APP_CFG" ]; then
  echo "WARNING: $ENC_FILE is not for application ${APP_CFG:-configured in .cloud-config.json}; not activating it."
  exit 0
fi
# ...and only this member's own secret: key_ids maps each member to theirs (an
# open rotation, which commits the new secret before key_ids names it, excepted;
# credentials from before keyId was stored carry none and are not checked)
WHY=$(jq -r --arg e "$USER_EMAIL" --arg k "$(jq -r '.keyId // empty' /tmp/credentials.json)" \
  '(if .providers then (.providers[] | select(.provider == "azure")) else . end) | (.key_ids // {}) as $m
  | if $k == "" then "ok"
    elif any($m | to_entries[]; .key != $e and (.value | split("/") | last) == $k) then "its secret is recorded for another member"
    elif ($m[$e] // "") != "" and ($m[$e] | split("/") | last) != $k and ((.rotating // {})[$e] // "") == "" then "its secret differs from the key_ids entry for this member"
    else "ok" end' "$CONFIG" 2>/dev/null)
if [ "$WHY" != ok ]; then
  echo "WARNING: $ENC_FILE not activated: ${WHY:-its secret could not be checked}."
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

AZ_ACTIVATED=1
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

In the usual remote setup, the user signs in on their own machine and pastes `ARM_TOKEN` and `GRAPH_TOKEN`; the `az` CLI in the sandbox is **not** signed in, and its commands do not read those variables. So use the REST calls with the pasted tokens, and use the CLI snippets only when `az account show` succeeds here (the CLI in this environment is itself signed in). The CLI snippets below check this and stop otherwise. REST calls:
- **ARM operations** (role assignments, subscriptions): `curl -H "Authorization: Bearer $ARM_TOKEN"` against `https://management.azure.com`
- **Graph operations** (app registrations, service principals, secrets): `curl -H "Authorization: Bearer $GRAPH_TOKEN"` against `https://graph.microsoft.com`

## Create Service Principal

```bash
# CLI path only: the az CLI here must itself be signed in (see API Approach);
# with pasted tokens, use the REST path below instead
az account show >/dev/null 2>&1 \
  || { echo "ERROR: az is not signed in here; use the REST path with ARM_TOKEN/GRAPH_TOKEN."; exit 1; }
# Work in the subscription (and so the tenant) the user named, not whatever the
# CLI has selected: the lookups and the app below follow the active one
[ -n "${SUBSCRIPTION_ID:-}" ] || { echo "ERROR: set SUBSCRIPTION_ID to the subscription gathered in Step 2; nothing created."; exit 1; }
az account set --subscription "$SUBSCRIPTION_ID" \
  && [ "$(az account show --query id -o tsv)" = "$SUBSCRIPTION_ID" ] \
  || { echo "ERROR: could not select subscription $SUBSCRIPTION_ID; nothing created."; exit 1; }
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

# The record must never be committed: make sure .gitignore covers it (setups
# made before it existed lack the rule)
grep -qxF '/.cloud-setup-pending.json' .gitignore 2>/dev/null || echo '/.cloud-setup-pending.json' >> .gitignore
# Create nothing unless git really ignores the plaintext and the record: a
# failed write (read-only file, full disk) would leave a live key committable
git check-ignore -q credentials.json && git check-ignore -q .cloud-setup-pending.json \
  || { echo "ERROR: .gitignore does not cover /credentials.json and /.cloud-setup-pending.json (First-Time Setup step 1a); nothing created."; exit 1; }
# The git email names the credential file and the member's key_ids entry: an
# empty one would leave a credential no later session can find
[ -n "$(git config user.email)" ] \
  || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry. Nothing created."; exit 1; }
# Record the name and subscription before creating anything (not secret), so
# "Rollback a Failed Setup" can find the application and its role assignments
# from any shell if this run stops part-way
[ -n "${SUBSCRIPTION_ID:-}" ] || { echo "ERROR: set SUBSCRIPTION_ID to the subscription gathered in Step 2; nothing created."; exit 1; }
jq -n --arg n "$SP_NAME" --arg s "$SUBSCRIPTION_ID" '{provider: "azure", sp_name: $n, subscription: $s}' \
  > .cloud-setup-pending.json || { echo "ERROR: could not write .cloud-setup-pending.json; nothing created."; exit 1; }
# Creating without a role assignment is the default (--skip-assignment is obsolete).
# The output holds the new client secret: write it private (0600) from the start.
(umask 077 && az ad sp create-for-rbac --name "$SP_NAME" > credentials.json)
# Record the new identity's IDs (not secret) as soon as they are known, so a
# rollback from a fresh shell finds them; if this fails, it finds the
# application by the recorded name instead
APP_ID=$(jq -r '.appId // empty' credentials.json 2>/dev/null)
SP_OBJECT_ID=""; [ -z "$APP_ID" ] || SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)
jq --arg a "$APP_ID" --arg p "$SP_OBJECT_ID" \
  '. + (if $a != "" then {app_id: $a} else {} end) + (if $p != "" then {sp_object_id: $p} else {} end)' \
  .cloud-setup-pending.json > .cloud-setup-pending.json.tmp && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json
[ -n "$APP_ID" ] || { echo "ERROR: create-for-rbac returned no appId; run Rollback a Failed Setup (it finds the app by name)."; exit 1; }
# Add the secret's keyId (not secret; the new app has exactly one secret), so a
# later rotation can find and revoke exactly this secret
KEY_ID=$(az ad app credential list --id "$APP_ID" --query '[0].keyId' -o tsv)
[ -n "$KEY_ID" ] || { echo "ERROR: could not read the new secret's keyId; run Rollback a Failed Setup."; exit 1; }
# The rewrite goes through a private temp file outside the repository (the
# only plaintext in the repo stays credentials.json, which is ignored and is
# what an interrupted-run check looks for)
TMPJ=$(umask 077 && mktemp)
if (umask 077 && jq --arg k "$KEY_ID" '. + {keyId: $k}' credentials.json > "$TMPJ") \
   && mv "$TMPJ" credentials.json; then :; else
  rm -f "$TMPJ"; echo "ERROR: could not add the keyId to credentials.json; run Rollback a Failed Setup."; exit 1
fi
```

This returns `appId`, `password` (client secret), and `tenant`; the snippet adds the secret's `keyId`.

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
# Graph responses (one holds the plaintext secret) go to a private temp dir
# outside the repo, removed on any exit, including an interruption
RESP_DIR=$(mktemp -d) && [ -d "$RESP_DIR" ] \
  || { echo "ERROR: could not create a private temp directory; nothing created."; exit 1; }
trap 'rm -rf "$RESP_DIR"' EXIT
cleanup_failed_setup() {
  # If the create call failed after Graph made the app (no ID came back),
  # find it by its unique per-run name
  if [ -z "$APP_OBJECT_ID" ] && [ -n "${SP_NAME:-}" ]; then
    # (Captured before jq: a failed lookup must not read as "no application")
    if R=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
         --data-urlencode "\$filter=displayName eq '$SP_NAME'" \
         -H "Authorization: Bearer $GRAPH_TOKEN"); then
      APP_OBJECT_ID=$(printf '%s' "$R" | jq -r '.value[0].id // empty') || APP_OBJECT_ID=""
    else
      echo "WARNING: could not look up application $SP_NAME; if it exists, run Rollback a Failed Setup."
    fi
  fi
  if [ -n "$APP_OBJECT_ID" ]; then
    if curl -sS --fail -X DELETE "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
         -H "Authorization: Bearer $GRAPH_TOKEN" >/dev/null; then
      rm -f .cloud-setup-pending.json   # nothing of this setup is left
    else
      echo "WARNING: could not delete application $APP_OBJECT_ID; run Rollback a Failed Setup."
    fi
  fi
  rm -f credentials.json
}
trap 'cleanup_failed_setup' ERR
# A signal is not a failed command, so ERR would not fire: roll back on those too
trap 'cleanup_failed_setup; exit 1' INT TERM HUP

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
# The record must never be committed: make sure .gitignore covers it (setups
# made before it existed lack the rule)
grep -qxF '/.cloud-setup-pending.json' .gitignore 2>/dev/null || echo '/.cloud-setup-pending.json' >> .gitignore
# Create nothing unless git really ignores the plaintext and the record: a
# failed write (read-only file, full disk) would leave a live key committable
git check-ignore -q credentials.json && git check-ignore -q .cloud-setup-pending.json \
  || { echo "ERROR: .gitignore does not cover /credentials.json and /.cloud-setup-pending.json (First-Time Setup step 1a); nothing created."; exit 1; }
# The git email names the credential file and the member's key_ids entry: an
# empty one would leave a credential no later session can find
[ -n "$(git config user.email)" ] \
  || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry. Nothing created."; exit 1; }
# Record the name and subscription before creating anything (not secret), so
# "Rollback a Failed Setup" can find the application and its role assignments
# from any shell if this run stops part-way
[ -n "${SUBSCRIPTION_ID:-}" ] || { echo "ERROR: set SUBSCRIPTION_ID to the subscription gathered in Step 2; nothing created."; exit 1; }
jq -n --arg n "$SP_NAME" --arg s "$SUBSCRIPTION_ID" '{provider: "azure", sp_name: $n, subscription: $s}' \
  > .cloud-setup-pending.json
(umask 077 && curl -sS --fail -X POST "https://graph.microsoft.com/v1.0/applications" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"displayName\": \"$SP_NAME\"}" > "$RESP_DIR/app.json")
APP_ID=$(jq -r '.appId // empty' "$RESP_DIR/app.json")
APP_OBJECT_ID=$(jq -r '.id // empty' "$RESP_DIR/app.json")
[ -n "$APP_ID" ] && [ -n "$APP_OBJECT_ID" ] || { echo "ERROR: application response lacks appId/id."; false; }
jq --arg a "$APP_ID" --arg o "$APP_OBJECT_ID" '. + {app_id: $a, app_object_id: $o}' .cloud-setup-pending.json \
  > .cloud-setup-pending.json.tmp && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json

# Step 2: Create service principal
(umask 077 && curl -sS --fail -X POST "https://graph.microsoft.com/v1.0/servicePrincipals" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"appId\": \"$APP_ID\"}" > "$RESP_DIR/sp.json")
SP_OBJECT_ID=$(jq -r '.id // empty' "$RESP_DIR/sp.json")
[ -n "$SP_OBJECT_ID" ] || { echo "ERROR: service principal response lacks id."; false; }
# Role assignments outlive their principal: record its object ID, so a
# rollback can remove them even after the principal itself is gone
jq --arg p "$SP_OBJECT_ID" '. + {sp_object_id: $p}' .cloud-setup-pending.json \
  > .cloud-setup-pending.json.tmp && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json

# Step 3: Add client secret
(umask 077 && curl -sS --fail -X POST "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID/addPassword" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -cn --arg n "claude-code-$(git config user.email)" '{passwordCredential: {displayName: $n}}')" > "$RESP_DIR/secret.json")
SECRET=$(jq -r '.secretText // empty' "$RESP_DIR/secret.json")
SECRET_KEY_ID=$(jq -r '.keyId // empty' "$RESP_DIR/secret.json")
[ -n "$SECRET" ] && [ -n "$SECRET_KEY_ID" ] || { echo "ERROR: addPassword response lacks secretText or keyId."; false; }

# Step 4: Assemble credentials. keyId (not secret) names exactly this secret,
# so a later rotation can find and revoke it.
(umask 077 && jq -n \
  --arg appId "$APP_ID" \
  --arg password "$SECRET" \
  --arg tenant "$TENANT_ID" \
  --arg keyId "$SECRET_KEY_ID" \
  '{appId: $appId, password: $password, tenant: $tenant, keyId: $keyId}' > credentials.json)

trap - ERR INT TERM HUP
echo "Created application $SP_NAME (object id $APP_OBJECT_ID). Keep APP_OBJECT_ID until setup finishes."
```

The tenant ID is collected first, before any Graph call creates anything, so a missing tenant never leaves a half-created application or a live secret on disk.

The trap above only covers this block: the agent may run each snippet in its own shell, where a trap cannot follow. Role grants, encryption, and the commit still come after it, so **if any later setup step fails, run the rollback below before retrying**. Otherwise the application and its live client secret stay behind, possibly with some roles already granted, and the name-collision check blocks a retry with the same name.

### Rollback a Failed Setup

```bash
# Delete the application created above (this removes its service principal and
# client secrets) after its role assignments, and the local plaintext. Works
# from any shell: the application is found from .cloud-setup-pending.json,
# else (no record) from APP_OBJECT_ID, APP_ID or SP_NAME, else from the appId in
# a leftover credentials.json. Needs GRAPH_TOKEN, plus ARM_TOKEN for role
# assignments.
PENDING=.cloud-setup-pending.json
pend() { jq -r --arg k "$1" 'select(.provider == "azure") | .[$k] // empty' "$PENDING" 2>/dev/null; }
# With a record, its identity wins: a value left in the shell by another
# operation must match it or be unset (shell values are used only without one)
HAVE_REC=$(jq -r 'select(.provider == "azure") | "yes"' "$PENDING" 2>/dev/null)
pick() {   # $1 = variable, $2 = the record's value
  [ -n "$HAVE_REC" ] || return 0
  [ -z "${!1:-}" ] || [ "${!1}" = "$2" ] \
    || { echo "ERROR: $1 is ${!1}, but $PENDING names ${2:-none}; nothing changed. Unset $1."; exit 1; }
  printf -v "$1" '%s' "$2"
}
pick APP_OBJECT_ID "$(pend app_object_id)"; pick SP_NAME "$(pend sp_name)"
pick SUBSCRIPTION_ID "$(pend subscription)"; pick APP_ID "$(pend app_id)"
APP_ID="${APP_ID:-$(jq -r '.appId // empty' credentials.json 2>/dev/null)}"
[ -n "$APP_OBJECT_ID" ] || [ -n "$APP_ID" ] || [ -n "$SP_NAME" ] \
  || { echo "ERROR: set APP_OBJECT_ID, APP_ID or SP_NAME from the failed setup's output (no $PENDING)."; exit 1; }
# Find the application. Entra replicates a new object for up to a few
# minutes, during which it can read as missing (404, or an empty filter
# result): call it gone (an earlier cleanup deleted it, or it was never
# created) only after it stays missing across retries
REC_OBJECT_ID="$APP_OBJECT_ID"; APP_OBJECT_ID=""
if [ -n "$APP_ID" ]; then F="appId eq '$APP_ID'"; else F="displayName eq '$SP_NAME'"; fi
for DELAY in 0 20 40 60; do
  sleep "$DELAY"
  if [ -n "$REC_OBJECT_ID" ]; then
    HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "https://graph.microsoft.com/v1.0/applications/$REC_OBJECT_ID" \
      -H "Authorization: Bearer $GRAPH_TOKEN")
    case "$HTTP" in
      200) APP_OBJECT_ID="$REC_OBJECT_ID"; break ;;
      404) ;;
      *) echo "ERROR: could not look the application up (HTTP $HTTP); nothing deleted. Retry."; exit 1 ;;
    esac
  else
    R=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" --data-urlencode "\$filter=$F" \
          -H "Authorization: Bearer $GRAPH_TOKEN") \
      || { echo "ERROR: could not look the application up; nothing deleted. Retry."; exit 1; }
    APP_OBJECT_ID=$(printf '%s' "$R" | jq -r '.value[0].id // empty')
    [ -z "$APP_OBJECT_ID" ] || break
  fi
done
RB_OK=1; RA_OK=1; APP_KIDS=""
# Role assignments are not removed with the service principal (they linger as
# "Identity not found" and count against the subscription's quota): delete
# the ones setup granted, by the principal's object ID, which still names them
# after the principal is gone. Needs ARM_TOKEN and SUBSCRIPTION_ID.
remove_role_assignments() {   # uses SP_OBJECT_ID; clears RA_OK on any failure
  if [ -z "${ARM_TOKEN:-}" ] || [ -z "${SUBSCRIPTION_ID:-}" ]; then
    RA_OK=0; echo "ERROR: set ARM_TOKEN and SUBSCRIPTION_ID so the role assignments can be removed."
  elif R=$(curl -sS --fail -G "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleAssignments" \
          --data-urlencode "api-version=2022-04-01" \
          --data-urlencode "\$filter=principalId eq '$SP_OBJECT_ID'" \
          -H "Authorization: Bearer $ARM_TOKEN"); then
    for RA in $(printf '%s' "$R" | jq -r '.value[].id'); do
      curl -sS --fail -X DELETE "https://management.azure.com${RA}?api-version=2022-04-01" \
        -H "Authorization: Bearer $ARM_TOKEN" >/dev/null || RA_OK=0
    done
  else
    RA_OK=0
  fi
}
if [ -n "$APP_OBJECT_ID" ]; then
  # Each lookup must succeed: an empty answer from a failed call would skip the
  # role assignments and then delete the application they belong to
  SP_OBJECT_ID=""
  if R=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
         -H "Authorization: Bearer $GRAPH_TOKEN") \
     && APP_ID=$(printf '%s' "$R" | jq -r '.appId // empty') && [ -n "$APP_ID" ] \
     && R=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/servicePrincipals" \
         --data-urlencode "\$filter=appId eq '$APP_ID'" -H "Authorization: Bearer $GRAPH_TOKEN"); then
    SP_OBJECT_ID=$(printf '%s' "$R" | jq -r '.value[0].id // empty')
  else
    RA_OK=0; echo "ERROR: could not look up the application or its service principal."
  fi
  # No principal found (never created, or deleted since): the recorded ID
  # still names its role assignments
  SP_OBJECT_ID="${SP_OBJECT_ID:-$(pend sp_object_id)}"
  [ "$RA_OK" = 0 ] || [ -z "$SP_OBJECT_ID" ] || remove_role_assignments
  if [ "$RA_OK" = 1 ]; then
    # Its secret IDs, for clearing their "unrevoked" entries once it is gone:
    # after the deletion they can no longer be read, so delete only once the
    # list was retrieved
    if R=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
           -H "Authorization: Bearer $GRAPH_TOKEN") \
       && APP_KIDS=$(printf '%s' "$R" | jq -er '[.passwordCredentials[].keyId] | join(" ")'); then
      HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
        -H "Authorization: Bearer $GRAPH_TOKEN")
      # Entra replicates a new application with a delay, so a 404 shortly
      # after creation may not mean it is gone: the absence must hold for
      # about a minute, and an application that reappears is deleted again
      if [ "$HTTP" = 404 ]; then
        for D in 20 20 20; do
          sleep "$D"
          G=$(curl -sS -o /dev/null -w '%{http_code}' "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
            -H "Authorization: Bearer $GRAPH_TOKEN")
          [ "$G" = 404 ] && continue
          if [ "$G" = 200 ]; then
            HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
              -H "Authorization: Bearer $GRAPH_TOKEN")
            [ "$HTTP" != 404 ] || HTTP="404 after reappearing"
          else
            HTTP="$G (lookup)"
          fi
          break
        done
      fi
      case "$HTTP" in
        204|404) echo "Application ${SP_NAME:-$APP_OBJECT_ID} is deleted." ;;
        *) RB_OK=0; echo "WARNING: could not delete application $APP_OBJECT_ID (HTTP $HTTP)." ;;
      esac
    else
      RB_OK=0; echo "WARNING: could not list the secrets of $APP_OBJECT_ID; the application is kept. Re-run this block."
    fi
  else
    # Keep the application: its service principal is how a retry finds the
    # remaining role assignments
    RB_OK=0; echo "WARNING: role assignments of ${SP_NAME:-$APP_OBJECT_ID} remain; the application is kept until they are removed."
  fi
else
  echo "No application found: nothing was created, or it is already deleted."
  # Its principal's role assignments can outlive it
  SP_OBJECT_ID="$(pend sp_object_id)"
  if [ -n "$SP_OBJECT_ID" ]; then
    remove_role_assignments
    [ "$RA_OK" = 1 ] || { RB_OK=0; echo "WARNING: role assignments of the deleted principal $SP_OBJECT_ID remain."; }
  fi
fi
if [ "$RB_OK" = 1 ]; then
  # The application and all its secrets are gone: drop the "unrevoked" entries
  # that name them (a failed discard may have recorded them), or every later
  # phase check would report credentials that no longer exist. That is the
  # secret IDs read before the deletion, and the discard script's entries for
  # this app ("app <appId>, ..."); entries for other apps stay
  if [ -f .cloud-config.json ]; then
    jq --arg a "$APP_ID" --arg ks "$APP_KIDS $(jq -r '.keyId // empty' credentials.json 2>/dev/null)" '
      ($ks | split(" ") | map(select(. != ""))) as $gone
      | .unrevoked = [(.unrevoked // [])[] | select(.provider != "azure"
          or ((.id | IN($gone[])) | not)
             and ($a == "" or (((.note // "") | startswith("app \($a), ")) | not)))]
      | if .unrevoked == [] then del(.unrevoked) else . end' .cloud-config.json > .cloud-config.json.tmp \
      && mv .cloud-config.json.tmp .cloud-config.json && echo "Commit .cloud-config.json if it changed." \
      || { rm -f .cloud-config.json.tmp; echo "ERROR: the identity is gone, but .cloud-config.json could not be updated; .cloud-setup-pending.json is kept. Fix the file and re-run this block."; exit 1; }
  fi
  rm -f credentials.json "$PENDING"; echo "Rollback complete."
else
  echo "Rollback incomplete; $PENDING is kept. Re-run this block."; exit 1
fi
```

With the CLI path (an `az` signed in with the bootstrap account), the same rollback is:

```bash
# Names from the setup record (works from a fresh shell), else credentials.json
pend() { jq -r --arg k "$1" 'select(.provider == "azure") | .[$k] // empty' .cloud-setup-pending.json 2>/dev/null; }
# With a record, its identity wins: a value left in the shell by another
# operation must match it or be unset (shell values are used only without one)
HAVE_REC=$(jq -r 'select(.provider == "azure") | "yes"' .cloud-setup-pending.json 2>/dev/null)
pick() {   # $1 = variable, $2 = the record's value
  [ -n "$HAVE_REC" ] || return 0
  [ -z "${!1:-}" ] || [ "${!1}" = "$2" ] \
    || { echo "ERROR: $1 is ${!1}, but .cloud-setup-pending.json names ${2:-none}; nothing changed. Unset $1."; exit 1; }
  printf -v "$1" '%s' "$2"
}
pick SUBSCRIPTION_ID "$(pend subscription)"; pick SP_NAME "$(pend sp_name)"
pick SP_OBJECT_ID "$(pend sp_object_id)"; pick APP_ID "$(pend app_id)"
APP_ID="${APP_ID:-$(jq -r '.appId // empty' credentials.json 2>/dev/null)}"
[ -n "$SUBSCRIPTION_ID" ] || { echo "ERROR: set SUBSCRIPTION_ID (no Azure entry in .cloud-setup-pending.json)."; exit 1; }
# Search the setup's subscription (and so its tenant), not whatever the CLI has
# selected: in another tenant the lookups below come back empty, and the
# rollback would wrongly conclude nothing was created
az account set --subscription "$SUBSCRIPTION_ID" \
  && [ "$(az account show --query id -o tsv)" = "$SUBSCRIPTION_ID" ] \
  || { echo "ERROR: could not select subscription $SUBSCRIPTION_ID; nothing deleted."; exit 1; }
# Interrupted before the IDs were saved: find the application by its
# per-run name, which the collision check proved unique
# (Entra can show a just-created application as missing for a few minutes:
# retry before concluding nothing was created)
if [ -z "$APP_ID" ] && [ -n "$SP_NAME" ]; then
  for DELAY in 0 20 40 60; do
    sleep "$DELAY"
    APP_ID=$(az ad app list --display-name "$SP_NAME" --query '[0].appId' -o tsv) \
      || { echo "ERROR: could not look up application $SP_NAME; nothing deleted."; exit 1; }
    [ -z "$APP_ID" ] || break
  done
fi
[ -n "$APP_ID" ] || [ -n "$SP_OBJECT_ID" ] \
  || { echo "No application named ${SP_NAME:-(unknown)} exists: nothing was created."; rm -f .cloud-setup-pending.json; rm -f credentials.json; exit 0; }
if [ -z "$SP_OBJECT_ID" ] && [ -n "$APP_ID" ]; then
  SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv) \
    || { echo "ERROR: could not look up the service principal of $APP_ID; nothing deleted."; exit 1; }
fi
# Role assignments are not removed with the application or its principal:
# delete every one of this principal in the setup's subscription (any scope),
# by object ID, which still names them after the principal is gone
if [ -n "$SP_OBJECT_ID" ]; then
  IDS=$(az role assignment list --subscription "$SUBSCRIPTION_ID" --all \
          --query "[?principalId=='$SP_OBJECT_ID'].id" -o tsv) \
    || { echo "ERROR: could not list role assignments; nothing deleted."; exit 1; }
  [ -z "$IDS" ] || az role assignment delete --ids $IDS --subscription "$SUBSCRIPTION_ID" \
    || { echo "ERROR: could not delete all role assignments; the application is kept. Re-run this block."; exit 1; }
  LEFT=$(az role assignment list --subscription "$SUBSCRIPTION_ID" --all \
           --query "length([?principalId=='$SP_OBJECT_ID'])" -o tsv)
  [ "$LEFT" = 0 ] || { echo "ERROR: role assignments of $SP_OBJECT_ID remain; the application is kept. Re-run this block."; exit 1; }
fi
# Only then delete the application (already gone counts as done)
# (a not-found answer counts only once it persists across retries: Entra can
# show a just-created application as missing for a few minutes)
APP_KIDS=""
if [ -n "$APP_ID" ]; then
  for DELAY in 0 20 40 60; do
    sleep "$DELAY"
    if OUT=$(az ad app show --id "$APP_ID" --query id -o tsv 2>&1); then
      # Its secret IDs, for clearing their "unrevoked" entries once it is gone
      # (after the deletion they can no longer be read: stop if listing fails)
      APP_KIDS=$(az ad app credential list --id "$APP_ID" --query '[].keyId' -o tsv) \
        || { echo "ERROR: could not list the secrets of $APP_ID; the application is kept. Re-run this block."; exit 1; }
      APP_KIDS=$(printf '%s' "$APP_KIDS" | tr '\n' ' ')
      az ad app delete --id "$APP_ID" || { echo "ERROR: could not delete application $APP_ID; re-run this block."; exit 1; }
      break
    elif ! printf '%s' "$OUT" | grep -qiE 'does not exist|ResourceNotFound|NotFound'; then
      echo "ERROR: could not look up application $APP_ID: $OUT"; exit 1
    fi
  done
fi
# The application and all its secrets are gone: drop the "unrevoked" entries
# that name them (a failed discard may have recorded them), or every later
# phase check would report credentials that no longer exist. That is the
# secret IDs read before the deletion, and the discard script's entries for
# this app ("app <appId>, ..."); entries for other apps stay
if [ -f .cloud-config.json ]; then
  jq --arg a "$APP_ID" --arg ks "$APP_KIDS $(jq -r '.keyId // empty' credentials.json 2>/dev/null)" '
    ($ks | split(" ") | map(select(. != ""))) as $gone
    | .unrevoked = [(.unrevoked // [])[] | select(.provider != "azure"
        or ((.id | IN($gone[])) | not)
           and ($a == "" or (((.note // "") | startswith("app \($a), ")) | not)))]
    | if .unrevoked == [] then del(.unrevoked) else . end' .cloud-config.json > .cloud-config.json.tmp \
    && mv .cloud-config.json.tmp .cloud-config.json && echo "Commit .cloud-config.json if it changed." \
    || { rm -f .cloud-config.json.tmp; echo "ERROR: the identity is gone, but .cloud-config.json could not be updated; .cloud-setup-pending.json is kept. Fix the file and re-run this block."; exit 1; }
fi
rm -f .cloud-setup-pending.json
rm -f credentials.json
echo "Rollback complete."
```

## Grant Roles

Roles are assigned to the **service principal**, so they apply to all team members automatically. No per-user role assignment needed.

```bash
# CLI path only: the az CLI here must itself be signed in (see API Approach)
az account show >/dev/null 2>&1 \
  || { echo "ERROR: az is not signed in here; use the REST path below with ARM_TOKEN/GRAPH_TOKEN."; exit 1; }
# APP_ID is the service principal's appId. During first-time setup it comes from
# the credentials you just created; in later sessions read it from config.
# This repo's application: the setup record's during first-time setup, else the
# configured one. An APP_ID left in the shell by another setup, or a stale
# credentials.json, must not receive the roles: a conflicting one stops here
WANT_APP=$(jq -r 'select(.provider=="azure") | .app_id // empty' .cloud-setup-pending.json 2>/dev/null)
WANT_APP="${WANT_APP:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else (select(.provider=="azure") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
for A in "${APP_ID:-}" "$(jq -r '.appId // empty' credentials.json 2>/dev/null)"; do
  [ -z "$A" ] || [ -z "$WANT_APP" ] || [ "$A" = "$WANT_APP" ] \
    || { echo "ERROR: application $A is not this repo's ($WANT_APP); nothing assigned. Unset APP_ID or check credentials.json."; exit 1; }
done
APP_ID="${WANT_APP:-${APP_ID:-$(jq -r '.appId // empty' credentials.json 2>/dev/null)}}"
[ -n "$APP_ID" ] || { echo "ERROR: could not resolve the app id from the setup record, .cloud-config.json or credentials.json."; exit 1; }

# During first-time setup .cloud-config.json does not exist yet: use the
# subscription ID gathered in Step 2, and read config only in later sessions.
# The same for the subscription: the setup record's, else the configured one
WANT_SUB=$(jq -r 'select(.provider=="azure") | .subscription // empty' .cloud-setup-pending.json 2>/dev/null)
WANT_SUB="${WANT_SUB:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .project_id) else (select(.provider=="azure") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)}"
[ -z "${SUBSCRIPTION_ID:-}" ] || [ -z "$WANT_SUB" ] || [ "$SUBSCRIPTION_ID" = "$WANT_SUB" ] \
  || { echo "ERROR: SUBSCRIPTION_ID is $SUBSCRIPTION_ID, but this repo's is $WANT_SUB; nothing assigned. Unset SUBSCRIPTION_ID."; exit 1; }
SUBSCRIPTION_ID="${WANT_SUB:-${SUBSCRIPTION_ID:-}}"
[ -n "$SUBSCRIPTION_ID" ] || { echo "ERROR: set SUBSCRIPTION_ID to the subscription gathered in Step 2."; exit 1; }
# Work in that subscription (and so its tenant), not whatever the CLI has
# selected: the directory lookup below follows the active one
az account set --subscription "$SUBSCRIPTION_ID" \
  && [ "$(az account show --query id -o tsv)" = "$SUBSCRIPTION_ID" ] \
  || { echo "ERROR: could not select subscription $SUBSCRIPTION_ID; nothing assigned."; exit 1; }
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
# This repo's application: the setup record's during first-time setup, else the
# configured one. An APP_ID left in the shell by another setup, or a stale
# credentials.json, must not receive the roles: a conflicting one stops here
WANT_APP=$(jq -r 'select(.provider=="azure") | .app_id // empty' .cloud-setup-pending.json 2>/dev/null)
WANT_APP="${WANT_APP:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else (select(.provider=="azure") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
for A in "${APP_ID:-}" "$(jq -r '.appId // empty' credentials.json 2>/dev/null)"; do
  [ -z "$A" ] || [ -z "$WANT_APP" ] || [ "$A" = "$WANT_APP" ] \
    || { echo "ERROR: application $A is not this repo's ($WANT_APP); nothing assigned. Unset APP_ID or check credentials.json."; exit 1; }
done
APP_ID="${WANT_APP:-${APP_ID:-$(jq -r '.appId // empty' credentials.json 2>/dev/null)}}"
[ -n "$APP_ID" ] || { echo "ERROR: could not resolve the app id from the setup record, .cloud-config.json or credentials.json."; exit 1; }
# During first-time setup .cloud-config.json does not exist yet: use the
# subscription ID gathered in Step 2, and read config only in later sessions.
# The same for the subscription: the setup record's, else the configured one
WANT_SUB=$(jq -r 'select(.provider=="azure") | .subscription // empty' .cloud-setup-pending.json 2>/dev/null)
WANT_SUB="${WANT_SUB:-$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .project_id) else (select(.provider=="azure") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)}"
[ -z "${SUBSCRIPTION_ID:-}" ] || [ -z "$WANT_SUB" ] || [ "$SUBSCRIPTION_ID" = "$WANT_SUB" ] \
  || { echo "ERROR: SUBSCRIPTION_ID is $SUBSCRIPTION_ID, but this repo's is $WANT_SUB; nothing assigned. Unset SUBSCRIPTION_ID."; exit 1; }
SUBSCRIPTION_ID="${WANT_SUB:-${SUBSCRIPTION_ID:-}}"
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
azcfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"azure\") | .$1) else (select(.provider==\"azure\") | .$1) end) // empty" .cloud-config.json 2>/dev/null; }
APP_ID=$(azcfg service_account)
# The configured tenant wins: a TENANT_ID left in the shell by another Azure
# operation would be written into the new credential, which then cannot log in
CFG_TENANT=$(azcfg tenant)
if [ -n "$CFG_TENANT" ]; then
  [ -z "${TENANT_ID:-}" ] || [ "$TENANT_ID" = "$CFG_TENANT" ] \
    || { echo "ERROR: TENANT_ID is $TENANT_ID, but .cloud-config.json has $CFG_TENANT; nothing created. Unset TENANT_ID."; exit 1; }
  TENANT_ID="$CFG_TENANT"
fi
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
[ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }

# The addPassword response holds the plaintext secret: keep it in a private
# temp dir outside the repo, removed on any exit, including an interruption
RESP_DIR=$(mktemp -d) && [ -d "$RESP_DIR" ] \
  || { echo "ERROR: could not create a private temp directory; nothing created."; exit 1; }
trap 'rm -rf "$RESP_DIR"' EXIT

# Add a new client secret labeled with the user's email. An HTTP 4xx means
# Graph rejected the request (no secret was created); a 5xx, a transport or
# local failure, or a response we cannot read leaves the outcome unknown. The
# secrets listed before the call tell which secrets are new since (the user's
# current secret carries the same label, so "newest with the label" is not
# enough); those are recorded for review, never removed blindly.
list_secret_ids() { local R; R=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  -H "Authorization: Bearer $GRAPH_TOKEN") && printf '%s' "$R" \
  | jq -r --arg n "claude-code-$USER_EMAIL" '.passwordCredentials[] | select(.displayName == $n) | .keyId'; }
SECRETS_BEFORE=$(list_secret_ids) || { echo "ERROR: could not list the app's secrets; nothing created."; exit 1; }
discard_unknown_secret() {
  echo "ERROR: $1; revoking any secret this call created."
  AFTER=$(list_secret_ids) \
    || { echo "WARNING: could not list secrets; check for a new claude-code-$USER_EMAIL secret by hand."; exit 1; }
  # (sed drops the empty line an empty list leaves, which grep -f would match everywhere)
  NEW=$(printf '%s\n' "$AFTER" | grep -vxF -f <(printf '%s\n' "$SECRETS_BEFORE" | sed '/^$/d') || true)
  [ -n "$NEW" ] || { echo "No new secret exists; nothing to revoke."; exit 1; }
  # Its secretText existed only in the response that never arrived, so nobody
  # holds it; but a new same-label secret may instead come from an overlapping
  # run of this member. Record the candidates for a person to check instead of
  # removing them (commit .cloud-config.json).
  UNREC=""
  for K in $NEW; do
    jq --arg id "$K" --arg m "$USER_EMAIL" --arg t "$(date -u +%FT%TZ)" \
      '.unrevoked = ((.unrevoked // []) + [{provider: "azure", id: $id, member: $m, ambiguous: true,
         note: "may be an unused secret from a failed addPassword call, or one an overlapping run created", at: $t}])' \
      .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
      || { rm -f .cloud-config.json.tmp; UNREC="$UNREC $K"; }
  done
  if [ -n "$UNREC" ]; then
    # Nothing durable names these secrets: stop with the IDs on screen
    echo "ERROR: could not record these secrets in .cloud-config.json (fix the file, then add them under \"unrevoked\" by hand):"
    printf '  %s\n' $UNREC
    exit 1
  fi
  echo "Secrets created since the request began (recorded as ambiguous under \"unrevoked\"):"; printf '  %s\n' $NEW
  echo "Remove each one no run of yours is using (not in key_ids once that run is committed)."
  exit 1
}
# From the request until credentials.json exists, the new secret is known only
# from the response in RESP_DIR (removed on exit, and not something the
# interrupted-run check sees): if this shell is stopped, revoke the secret a
# complete response names, else record the candidates as above
on_signal() {
  local K; K=$(jq -r '.keyId // empty' "$RESP_DIR/secret.json" 2>/dev/null)
  if [ -n "$K" ]; then
    CRED_ID="$K" CRED_ID_FROM_RESPONSE=1 OBJECT_ID="$OBJECT_ID" GRAPH_TOKEN="$GRAPH_TOKEN" \
      bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh azure
    exit 1
  fi
  discard_unknown_secret "interrupted during addPassword"
}
trap on_signal INT TERM HUP
# (if/else so the status is captured even under `set -e`)
if HTTP=$(umask 077 && curl -sS -o "$RESP_DIR/secret.json" -w '%{http_code}' -X POST \
  "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/addPassword" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -cn --arg n "claude-code-$USER_EMAIL" '{passwordCredential: {displayName: $n}}')"); then RC=0; else RC=$?; fi
case "$RC:$HTTP" in
  0:2??) ;;
  0:4??) trap - INT TERM HUP; echo "ERROR: Graph rejected addPassword (HTTP $HTTP); no secret was created."; exit 1 ;;
  *) discard_unknown_secret "addPassword outcome unknown (curl exit $RC, HTTP ${HTTP:-none})" ;;
esac
SECRET=$(jq -r '.secretText // empty' "$RESP_DIR/secret.json")
# Keep the new secret's keyId: removePassword needs it if a later step fails
NEW_SECRET_KEY_ID=$(jq -r '.keyId // empty' "$RESP_DIR/secret.json")
[ -n "$SECRET" ] && [ -n "$NEW_SECRET_KEY_ID" ] \
  || discard_unknown_secret "addPassword response has no secretText or keyId"
echo "New secret keyId: $NEW_SECRET_KEY_ID (OBJECT_ID=$OBJECT_ID)"

# Assemble credentials (appId and tenant are the same for all team members).
# keyId (not secret) identifies exactly this secret for later cleanup and
# rotation, even when several runs use the same member label.
(umask 077 && jq -n \
  --arg appId "$APP_ID" \
  --arg password "$SECRET" \
  --arg tenant "$TENANT_ID" \
  --arg keyId "$NEW_SECRET_KEY_ID" \
  '{appId: $appId, password: $password, tenant: $tenant, keyId: $keyId}' > credentials.json) \
  || { rm -f credentials.json; echo "ERROR: could not write credentials.json; revoking the new secret."
       CRED_ID="$NEW_SECRET_KEY_ID" CRED_ID_FROM_RESPONSE=1 OBJECT_ID="$OBJECT_ID" GRAPH_TOKEN="$GRAPH_TOKEN" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh azure
       trap - INT TERM HUP; exit 1; }
# credentials.json now marks the run as unfinished for the next session
trap - INT TERM HUP

# Record which secret is this member's (not secret), so offboarding can find
# it without the member's passphrase; commit .cloud-config.json with the .enc
# A different secret already recorded for this member (re-onboarding after
# the .enc went missing) may still be live: queue it in revoke_pending
OLD_KEY=$(jq -r --arg e "$USER_EMAIL" '(if .providers then (.providers[] | select(.provider=="azure")) else . end) | .key_ids[$e] // empty' .cloud-config.json)
if ! { jq --arg e "$USER_EMAIL" --arg k "$NEW_SECRET_KEY_ID" '
  def rec: (if (.key_ids[$e] // "") != "" and .key_ids[$e] != $k
      then .revoke_pending[$e] = (((.revoke_pending[$e] // []) | if type == "string" then [.] else . end) + [.key_ids[$e]] | unique)
      else . end) | .key_ids[$e] = $k;
  if .providers then .providers |= map(if .provider == "azure" then rec else . end)
  else rec end' .cloud-config.json > .cloud-config.json.tmp \
  && mv .cloud-config.json.tmp .cloud-config.json; }; then
  rm -f .cloud-config.json.tmp
  echo "ERROR: could not record the secret in .cloud-config.json; revoking it."
  CRED_ID="$NEW_SECRET_KEY_ID" OBJECT_ID="$OBJECT_ID" GRAPH_TOKEN="$GRAPH_TOKEN" \
    bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh azure
  exit 1
fi
[ -z "$OLD_KEY" ] || [ "$OLD_KEY" = "$NEW_SECRET_KEY_ID" ] \
  || echo "NOTE: $OLD_KEY was recorded for $USER_EMAIL and is now queued in revoke_pending; revoke it (Credential Rotation step 9)."
```

**Note:** The `.cloud-config.json` for Azure should also store `tenant` alongside the other fields.

## Secret Management

Resolve the application first (later sessions have no `OBJECT_ID` in scope), then list its client secrets (requires `$GRAPH_TOKEN`):

```bash
APP_ID=$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else (select(.provider=="azure") | .service_account) end) // empty' .cloud-config.json)
OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
  --data-urlencode "\$filter=appId eq '$APP_ID'" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
[ -n "$OBJECT_ID" ] || { echo "ERROR: could not resolve the application for appId '$APP_ID'."; exit 1; }

curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq '.passwordCredentials[] | {displayName, keyId, endDateTime}'
```

Remove a team member's secrets (if they leave); the block resolves the application itself. This removes every secret the member still has: their current one (`key_ids` in `.cloud-config.json`) and any old ones in their `revoke_pending` list. Each ID leaves the config as soon as Graph confirms its removal (HTTP 204), and the credential file goes only when none remain, so the repo never drops the record of a secret that is still live. It also removes every secret labelled `claude-code-<email>` (the label setup gives each member's secret), which covers members added before `key_ids` existed; a secret the config records for another member is left alone. For an unlabelled secret, set `KEY_ID` to it and, once the user has confirmed it is the member's, `CONFIRM_KEY=1`; a `KEY_ID` the config records for another member is refused.

```bash
MEMBER_EMAIL="departed-user@example.com"
# Resolve the application here too: this block may run in a fresh shell
APP_ID=$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else (select(.provider=="azure") | .service_account) end) // empty' .cloud-config.json)
OBJECT_ID=$( [ -n "$APP_ID" ] && curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
  --data-urlencode "\$filter=appId eq '$APP_ID'" \
  -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
[ -n "$OBJECT_ID" ] || { echo "ERROR: could not resolve the application for appId '$APP_ID'."; exit 1; }
# Every recorded credential of this member: current (key_ids), queued old ones
# (revoke_pending), one an interrupted rotation saved (rotating), and any a
# failed cleanup recorded as unrevoked
IDS=$(jq -r --arg e "$MEMBER_EMAIL" '
  ([.unrevoked[]? | select(.provider == "azure" and .member == $e and (.ambiguous | not)) | .id | split("/") | last
     | select(test(" ") | not)]) as $u   # placeholders such as "unknown key of ..." name no ID
  | (if .providers then (.providers[] | select(.provider=="azure")) else . end)
  | ([.key_ids[$e] // empty, .rotating[$e] // empty] + ((.revoke_pending[$e] // []) | if type == "string" then [.] else . end) + $u) | unique | .[]' .cloud-config.json)
# Plus every secret carrying this member's label: a member added before
# key_ids existed, or a secret a failed run never recorded, has no other
# record. A labelled secret the config gives to another member stays.
# (The response is captured before jq reads it: in a pipeline, a failed
# request would give jq empty input and pass as "no labelled secrets")
APP_JSON=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  -H "Authorization: Bearer $GRAPH_TOKEN") \
  && LABELLED=$(printf '%s' "$APP_JSON" | jq -r --arg n "claude-code-$MEMBER_EMAIL" \
    '(.passwordCredentials | if type == "array" then . else error("no secret list") end)[]
     | select(.displayName == $n) | .keyId') \
  || { echo "ERROR: could not list the application's secrets; nothing removed."; exit 1; }
OTHERS=$(jq -r --arg e "$MEMBER_EMAIL" '(if .providers then (.providers[] | select(.provider=="azure")) else . end)
  | [(.key_ids // {}), (.rotating // {}), (.revoke_pending // {})][] | to_entries[] | select(.key != $e)
  | .value | (if type == "array" then .[] else . end)' .cloud-config.json)
for K in $LABELLED; do printf '%s\n' $OTHERS | grep -qxF "$K" || IDS="$IDS $K"; done
# A KEY_ID override must not be another member's secret, and one neither
# recorded for nor labelled for this member needs CONFIRM_KEY=1 once the person
# has checked it is theirs: a stale or mistyped ID would otherwise remove a
# teammate's working secret
if [ -n "${KEY_ID:-}" ]; then
  ! printf '%s\n' $OTHERS | grep -qxF "$KEY_ID" \
    || { echo "ERROR: KEY_ID $KEY_ID is recorded for another member; nothing removed."; exit 1; }
  printf '%s\n' $IDS | grep -qxF "$KEY_ID" || [ "${CONFIRM_KEY:-}" = 1 ] \
    || { echo "ERROR: KEY_ID $KEY_ID is not recorded or labelled for $MEMBER_EMAIL. Confirm it is theirs, then rerun with CONFIRM_KEY=1; nothing removed."; exit 1; }
fi
IDS=$(printf '%s\n' $IDS ${KEY_ID:-} | sort -u)
if [ -z "$IDS" ]; then
  # A compromise rotation may already have deleted the member's only
  # credential (revoked_early, no replacement): nothing is live, so clear the
  # member's local state directly
  if [ -n "$(jq -r --arg e "$MEMBER_EMAIL" '(if .providers then (.providers[] | select(.provider=="azure")) else . end) | .revoked_early[$e] // empty' .cloud-config.json)" ]; then
    jq --arg e "$MEMBER_EMAIL" 'def clr: del(.revoked_early[$e]) | del(.key_ids[$e]) | del(.rotating[$e]) | del(.revoke_pending[$e]);
      if .providers then .providers |= map(if .provider == "azure" then clr else . end) else clr end' \
      .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
      || { rm -f .cloud-config.json.tmp; echo "ERROR: could not update .cloud-config.json; the credential file stays. Fix it and retry."; exit 1; }
    git --literal-pathspecs rm -q --ignore-unmatch ".cloud-credentials.azure.${MEMBER_EMAIL}.enc" ".cloud-credentials.${MEMBER_EMAIL}.enc"
    echo "$MEMBER_EMAIL has no live credential left; local state cleared."; exit 0
  fi
  echo "ERROR: no recorded secret for $MEMBER_EMAIL; set KEY_ID from the listing first."; exit 1
fi
FAILED=""
# The app's current secret IDs: a secret it no longer lists is already gone
# (an earlier attempt removed it, or its response was lost)
secret_absent() {
  local R; R=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
    -H "Authorization: Bearer $GRAPH_TOKEN") \
    && printf '%s' "$R" | jq -e --arg k "$1" 'all(.passwordCredentials[]; .keyId != $k)' >/dev/null
}
for ID in $IDS; do
  STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/removePassword" \
    -H "Authorization: Bearer $GRAPH_TOKEN" -H "Content-Type: application/json" \
    -d "{\"keyId\": \"$ID\"}")
  [ "$STATUS" = "204" ] || ! secret_absent "$ID" || STATUS=204
  if [ "$STATUS" = "204" ]; then
    jq --arg e "$MEMBER_EMAIL" --arg id "$ID" '
      def clr: (if .key_ids[$e] == $id then del(.key_ids[$e]) else . end)
        | (if .revoke_pending[$e] then .revoke_pending[$e] = ((.revoke_pending[$e] | if type == "string" then [.] else . end) - [$id]) else . end)
        | (if .revoke_pending[$e] == [] then del(.revoke_pending[$e]) else . end)
        | (if .rotating[$e] == $id then del(.rotating[$e]) else . end)
        | del(.revoked_early[$e]);   # its key is gone; a rejoining member starts fresh
      .unrevoked = [(.unrevoked // [])[] | select(.provider != "azure" or .member != $e or (.id | split("/") | last) != $id)]
      | if .unrevoked == [] then del(.unrevoked) else . end
      | if .providers then .providers |= map(if .provider == "azure" then clr else . end) else clr end' \
      .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
      || { echo "ERROR: secret $ID removed but .cloud-config.json not updated."; FAILED="$FAILED $ID"; }
  else
    echo "ERROR: removePassword for $ID returned HTTP $STATUS; it may still be active."
    FAILED="$FAILED $ID"
  fi
done
[ -z "$FAILED" ] || { echo "Still to do:$FAILED. The credential file stays; retry."; exit 1; }
# Every labelled secret is gone, so a "secret labelled ..." placeholder the
# discard script recorded for this member is resolved too
jq --arg e "$MEMBER_EMAIL" '.unrevoked = [(.unrevoked // [])[] | select(.provider != "azure" or .member != $e
    or .id != "secret labelled claude-code-\($e)")] | if .unrevoked == [] then del(.unrevoked) else . end' \
  .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
  || { rm -f .cloud-config.json.tmp; echo "ERROR: could not update .cloud-config.json; the credential file stays. Retry."; exit 1; }
git --literal-pathspecs rm -q --ignore-unmatch ".cloud-credentials.azure.${MEMBER_EMAIL}.enc" ".cloud-credentials.${MEMBER_EMAIL}.enc"
```

Commit the removed credential file and `.cloud-config.json` together.

## Activate (Subsequent Sessions)

After decrypting credentials to `/tmp/credentials.json`:

```bash
# Only a credential for the configured application (not a stale or copied one)
APP_CFG=$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .service_account) else (select(.provider=="azure") | .service_account) end) // empty' .cloud-config.json)
# On any failure, log out: az keeps an earlier cached login, and later
# commands would otherwise run as it although this activation failed
[ -n "$APP_CFG" ] && [ "$(jq -r '.appId // empty' /tmp/credentials.json)" = "$APP_CFG" ] \
  || { az logout >/dev/null 2>&1; rm -f /tmp/credentials.json; echo "ERROR: the credential is not for application ${APP_CFG:-configured in .cloud-config.json}; logged out."; exit 1; }
# ...and only this member's own secret: key_ids maps each member to theirs (an
# open rotation, which commits the new secret before key_ids names it, excepted;
# credentials from before keyId was stored carry none and are not checked)
WHY=$(jq -r --arg e "$(git config user.email)" --arg k "$(jq -r '.keyId // empty' /tmp/credentials.json)" \
  '(if .providers then (.providers[] | select(.provider == "azure")) else . end) | (.key_ids // {}) as $m
  | if $k == "" then "ok"
    elif any($m | to_entries[]; .key != $e and (.value | split("/") | last) == $k) then "its secret is recorded for another member"
    elif ($m[$e] // "") != "" and ($m[$e] | split("/") | last) != $k and ((.rotating // {})[$e] // "") == "" then "its secret differs from the key_ids entry for this member"
    else "ok" end' .cloud-config.json 2>/dev/null)
[ "$WHY" = ok ] || { az logout >/dev/null 2>&1; rm -f /tmp/credentials.json; echo "ERROR: the credential was not activated: ${WHY:-its secret could not be checked}; logged out."; exit 1; }
az login --service-principal \
  --username "$(jq -r .appId /tmp/credentials.json)" \
  --password "$(jq -r .password /tmp/credentials.json)" \
  --tenant "$(jq -r .tenant /tmp/credentials.json)" \
  || { az logout >/dev/null 2>&1; rm -f /tmp/credentials.json; echo "ERROR: az login failed (the secret may be revoked or expired); logged out."; exit 1; }

# Provider-aware subscription: in multi-provider repos the subscription id is in
# the matching providers[] entry, not at top-level .project_id.
az account set --subscription "$(jq -r '(if .providers then (.providers[] | select(.provider=="azure") | .project_id) else (select(.provider=="azure") | .project_id) end)' .cloud-config.json)" \
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
