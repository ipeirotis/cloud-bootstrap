# Azure Reference

## User Prerequisites

The user needs **Owner** or **User Access Administrator + Contributor** role on the Azure subscription, plus **Application Administrator** in Entra ID (formerly Azure AD) to create service principals.

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
  "https://management.azure.com/$ROLE_DEFINITION_ID/providers/Microsoft.Authorization/roleAssignments/$(uuidgen)?api-version=2022-04-01" \
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

## Activate (Subsequent Sessions)

After decrypting credentials to `/tmp/credentials.json`:

```bash
az login --service-principal \
  --username $(jq -r .appId /tmp/credentials.json) \
  --password $(jq -r .password /tmp/credentials.json) \
  --tenant $(jq -r .tenant /tmp/credentials.json)

az account set --subscription $(jq -r .project_id .cloud-config.json)

rm -f /tmp/credentials.json
```

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
