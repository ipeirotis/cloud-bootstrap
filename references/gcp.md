# GCP Reference

## User Prerequisites (First-Time Setup)

The user's GCP account needs **Owner** or **Service Account Admin + Project IAM Admin** roles on the project.

## Team Member Prerequisites (Adding to Existing Setup)

The user's GCP account needs **Service Account Key Admin** on the project (or on the specific service account). This is a narrower permission than what the first user needs.

## Key Limits

GCP allows **10 keys per service account**. This means up to 10 team members can each have their own key. If you hit this limit, you can list and delete unused keys (see "Key Management" below).

## Bootstrap Token Command

Tell the user to run locally:

```bash
gcloud auth login          # if not already logged in
gcloud config set project PROJECT_ID
gcloud auth print-access-token
```

This produces a token valid for ~1 hour.

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
gcloud config set project $(jq -r .project_id .cloud-config.json)
rm -f /tmp/credentials.json
```

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
