# GCP Reference

## User Prerequisites

The user's GCP account needs **Owner** or **Service Account Admin + Project IAM Admin** roles on the project.

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

```bash
curl -X POST \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/claude-agent@$PROJECT_ID.iam.gserviceaccount.com/keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keyAlgorithm": "KEY_ALG_RSA_2048"}' \
  | jq -r '.privateKeyData' | base64 -d > credentials.json
```

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
