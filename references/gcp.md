# GCP Reference

## User Prerequisites (First-Time Setup)

The user's GCP account needs **Owner** or **Service Account Admin + Project IAM Admin** roles on the project.

## Team Member Prerequisites (Adding to Existing Setup)

The user's GCP account needs **Service Account Key Admin** on the project (or on the specific service account). This is a narrower permission than what the first user needs.

## Key Limits

GCP allows **10 keys per service account**. This means up to 10 team members can each have their own key. If you hit this limit, you can list and delete unused keys (see "Key Management" below).

## Bootstrap Token Command

Tell the user to run in [Google Cloud Shell](https://console.cloud.google.com) (click the ">_" terminal icon in the Cloud Console) or on their local machine if they have `gcloud` installed:

```bash
gcloud config set project PROJECT_ID
gcloud auth print-access-token
```

This produces a token valid for ~1 hour.

## CLI Installation

The Claude Code on the Web sandbox does not have `gcloud` pre-installed. Use this script to install it:

```bash
if ! command -v gcloud &> /dev/null; then
  curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/home/user
  export PATH="/home/user/google-cloud-sdk/bin:$PATH"
fi
```

### SessionStart Hook

After setup completes, create a SessionStart hook that installs the CLI **and** authenticates automatically. Create `.claude/hooks/cloud-auth.sh`:

```bash
#!/bin/bash
set -e

# --- Install gcloud if missing ---
if ! command -v gcloud &> /dev/null; then
  curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/home/user
  export PATH="/home/user/google-cloud-sdk/bin:$PATH"
fi

# --- Auto-authenticate if credentials exist ---
CONFIG=".cloud-config.json"
if [ ! -f "$CONFIG" ]; then exit 0; fi

PROVIDER=$(jq -r .provider "$CONFIG" 2>/dev/null)
if [ "$PROVIDER" != "gcp" ]; then exit 0; fi

USER_EMAIL=$(git config user.email 2>/dev/null || true)
ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
if [ -z "$USER_EMAIL" ] || [ ! -f "$ENC_FILE" ]; then exit 0; fi

KEY="${GCP_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}"
if [ -z "$KEY" ]; then exit 0; fi

echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null || exit 0

gcloud auth activate-service-account --key-file=/tmp/credentials.json 2>/dev/null
gcloud config set project "$(jq -r .project_id "$CONFIG")" 2>/dev/null
rm -f /tmp/credentials.json

echo "GCP credentials activated for $USER_EMAIL"
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

## API Base

All API calls use `curl -H "Authorization: Bearer $TOKEN"` against `https://` endpoints.

## Create Service Account

```bash
# Create the service account
curl -X POST \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "accountId": "claude-agent",
    "serviceAccount": {
      "displayName": "Claude Code Agent"
    }
  }'
```

The service account email will be: `claude-agent@$PROJECT_ID.iam.gserviceaccount.com`

## Grant Roles

For each role:

```bash
# Get current IAM policy
curl -X POST \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT_ID:getIamPolicy" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'

# Set updated policy with new binding added
curl -X POST \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT_ID:setIamPolicy" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "policy": {
      "bindings": [
        ... existing bindings ...,
        {
          "role": "roles/ROLE_NAME",
          "members": ["serviceAccount:claude-agent@'$PROJECT_ID'.iam.gserviceaccount.com"]
        }
      ]
    }
  }'
```

**Important:** Merge new bindings with existing ones. Do not overwrite the entire policy.

## Create Key

This command works for both first-time setup and adding new team members. Each call creates a new, independent key for the same service account.

```bash
curl -X POST \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/claude-agent@$PROJECT_ID.iam.gserviceaccount.com/keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keyAlgorithm": "KEY_ALG_RSA_2048"}' \
  | jq -r '.privateKeyData' | base64 -d > credentials.json
```

## Key Management

List existing keys (useful if approaching the 10-key limit):

```bash
curl -X GET \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/claude-agent@$PROJECT_ID.iam.gserviceaccount.com/keys" \
  -H "Authorization: Bearer $TOKEN"
```

Delete a specific key (if a team member leaves or a key is compromised):

```bash
curl -X DELETE \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/claude-agent@$PROJECT_ID.iam.gserviceaccount.com/keys/KEY_ID" \
  -H "Authorization: Bearer $TOKEN"
```

Also remove the corresponding `.cloud-credentials.<email>.enc` file from the repo.

## Activate (Subsequent Sessions)

After decrypting credentials to `/tmp/credentials.json`:

```bash
gcloud auth activate-service-account --key-file=/tmp/credentials.json
gcloud config set project "$(jq -r .project_id .cloud-config.json)"
rm -f /tmp/credentials.json
```

## Verify (Smoke Test)

After activating credentials, run this lightweight check to confirm they work:

```bash
gcloud projects describe "$(jq -r .project_id .cloud-config.json)" --format="value(projectId)"
```

If this fails with a permission error, the credentials may be expired or revoked. Re-run the **Authenticate** flow or ask the user to check the service account.

## Common Roles Reference

| Need | Role |
|------|------|
| Deploy Cloud Functions | `roles/cloudfunctions.developer` |
| Manage Cloud Run | `roles/run.developer` |
| Read/write GCS buckets | `roles/storage.objectAdmin` |
| Manage Pub/Sub | `roles/pubsub.editor` |
| Query BigQuery | `roles/bigquery.dataEditor` + `roles/bigquery.jobUser` |
| Deploy App Engine | `roles/appengine.deployer` |
| Manage Cloud SQL | `roles/cloudsql.editor` |
| View logs | `roles/logging.viewer` |
| Manage secrets | `roles/secretmanager.secretAccessor` |
