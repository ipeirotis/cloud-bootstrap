# Azure Reference

## User Prerequisites (First-Time Setup)

The user needs **Owner** or **User Access Administrator + Contributor** role on the Azure subscription, plus **Application Administrator** in Entra ID (formerly Azure AD) to create service principals.

## Team Member Prerequisites (Adding to Existing Setup)

The user needs **Application Administrator** (or **Cloud Application Administrator**) in Entra ID to add a client secret to the existing app registration. No subscription-level role is needed since roles are already assigned to the service principal.

## Key Limits

Azure allows **unlimited client secrets per app registration**. Each team member gets their own client secret for the same application/service principal. No practical team size limit.

## CLI Installation

The Claude Code on the Web sandbox may not have `az` pre-installed. Use this script to install it:

```bash
if ! command -v az &> /dev/null; then
  curl -sSL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi
```

### SessionStart Hook

After setup completes, create a SessionStart hook that installs the CLI **and** authenticates automatically. Create `.claude/hooks/cloud-auth.sh`:

```bash
#!/bin/bash
set -e

# --- Install az CLI if missing ---
if ! command -v az &> /dev/null; then
  curl -sSL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

# --- Auto-authenticate if credentials exist ---
CONFIG=".cloud-config.json"
if [ ! -f "$CONFIG" ]; then exit 0; fi

PROVIDER=$(jq -r .provider "$CONFIG" 2>/dev/null)
if [ "$PROVIDER" != "azure" ]; then exit 0; fi

USER_EMAIL=$(git config user.email 2>/dev/null || true)
ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
if [ -z "$USER_EMAIL" ] || [ ! -f "$ENC_FILE" ]; then exit 0; fi

KEY="${AZURE_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}"
if [ -z "$KEY" ]; then exit 0; fi

echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null || exit 0

az login --service-principal \
  --username "$(jq -r .appId /tmp/credentials.json)" \
  --password "$(jq -r .password /tmp/credentials.json)" \
  --tenant "$(jq -r .tenant /tmp/credentials.json)" 2>/dev/null

az account set --subscription "$(jq -r .project_id "$CONFIG")" 2>/dev/null
rm -f /tmp/credentials.json

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
az account get-access-token --query accessToken -o tsv
```

This produces a token valid for ~1 hour.

## API Approach

Use the Azure CLI (`az`) if available. Otherwise, use REST API calls with `curl -H "Authorization: Bearer $TOKEN"` against `https://management.azure.com` and `https://graph.microsoft.com`.

## Create Service Principal

```bash
# Using Azure CLI with the bootstrap token context
az ad sp create-for-rbac \
  --name claude-agent \
  --skip-assignment \
  > credentials.json
```

This returns `appId`, `password` (client secret), and `tenant`. The credentials file is already in the right format.

If `az` is not available, use the Microsoft Graph API:

```bash
# Step 1: Create application
curl -X POST "https://graph.microsoft.com/v1.0/applications" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"displayName": "claude-agent"}' \
  > app.json

APP_ID=$(jq -r .appId app.json)
OBJECT_ID=$(jq -r .id app.json)

# Step 2: Create service principal
curl -X POST "https://graph.microsoft.com/v1.0/servicePrincipals" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"appId\": \"$APP_ID\"}"

# Step 3: Add client secret
curl -X POST "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/addPassword" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"passwordCredential": {"displayName": "claude-code"}}' \
  > secret.json

# Step 4: Assemble credentials
TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null || echo "ASK_USER")
jq -n \
  --arg appId "$APP_ID" \
  --arg password "$(jq -r .secretText secret.json)" \
  --arg tenant "$TENANT_ID" \
  '{appId: $appId, password: $password, tenant: $tenant}' \
  > credentials.json

rm -f app.json secret.json
```

If the tenant ID is not available, ask the user.

## Grant Roles

Roles are assigned to the **service principal**, so they apply to all team members automatically. No per-user role assignment needed.

```bash
SUBSCRIPTION_ID=$(jq -r .project_id .cloud-config.json)
SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query id -o tsv)

az role assignment create \
  --assignee-object-id $SP_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "ROLE_NAME" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

Or via REST API:

```bash
ROLE_DEFINITION_ID=$(curl -s "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&\$filter=roleName eq 'ROLE_NAME'" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.value[0].id')

curl -X PUT \
  "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleAssignments/$(uuidgen)?api-version=2022-04-01" \
  -H "Authorization: Bearer $TOKEN" \
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
# Get the app's object ID from its appId
APP_ID=$(jq -r .service_account .cloud-config.json)
OBJECT_ID=$(curl -s "https://graph.microsoft.com/v1.0/applications?\$filter=appId eq '$APP_ID'" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.value[0].id')

USER_EMAIL=$(git config user.email)

# Add a new client secret labeled with the user's email
curl -X POST "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/addPassword" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"passwordCredential\": {\"displayName\": \"claude-code-${USER_EMAIL}\"}}" \
  > secret.json

# Assemble credentials (appId and tenant are the same for all team members)
TENANT_ID=$(jq -r .tenant .cloud-config.json 2>/dev/null || echo "ASK_USER")
jq -n \
  --arg appId "$APP_ID" \
  --arg password "$(jq -r .secretText secret.json)" \
  --arg tenant "$TENANT_ID" \
  '{appId: $appId, password: $password, tenant: $tenant}' \
  > credentials.json

rm -f secret.json
```

**Note:** The `.cloud-config.json` for Azure should also store `tenant` alongside the other fields.

## Secret Management

List client secrets for the app:

```bash
curl -s "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  -H "Authorization: Bearer $TOKEN" | jq '.passwordCredentials[] | {displayName, keyId, endDateTime}'
```

Remove a specific client secret (if a team member leaves):

```bash
curl -X POST "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/removePassword" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keyId": "KEY_ID_TO_REMOVE"}'
```

Also remove the corresponding `.cloud-credentials.<email>.enc` file from the repo.

## Activate (Subsequent Sessions)

After decrypting credentials to `/tmp/credentials.json`:

```bash
az login --service-principal \
  --username "$(jq -r .appId /tmp/credentials.json)" \
  --password "$(jq -r .password /tmp/credentials.json)" \
  --tenant "$(jq -r .tenant /tmp/credentials.json)"

az account set --subscription "$(jq -r .project_id .cloud-config.json)"

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
