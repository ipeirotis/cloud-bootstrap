# Add Team Member

This flow runs when `.cloud-config.json` exists (the service account is already set up) but the current user has no encrypted credentials file yet.

## Step 1: Read Existing Config

Read `.cloud-config.json` to get the provider, project ID, and service account identity. Read the corresponding provider reference file.

## Step 2: Explain and Get Bootstrap Token

Tell the user:

```
This repo already has cloud access configured:
  Provider: <provider>
  Project: <project_id>
  Service account: <service_account>
  Roles: <roles>

I need to create a new key for this service account, encrypted with your
personal passphrase. This means you won't need anyone else's password.

Please run this on your local machine and paste the result:
  <bootstrap token command from provider reference>
```

Tell them the specific permission needed from the provider reference file (see "Team Member Prerequisites" in each reference).

## Step 3: Create New Key and Encrypt

Using the bootstrap token and provider-specific commands:

1. Create the new member's credential:
   - **GCP / Azure:** create a **new key** (GCP) or client secret (Azure) for the **existing** service account or app (do NOT create a new one). See the "Add Key for Existing Service Account" / "Add Client Secret" section in the provider reference.
   - **AWS:** the configured `service_account` is the shared IAM **group**, and access keys belong to users, not groups. Create a **new IAM user for this member in the existing group**, then its access key, following "Add Team Member: Create New User in Existing Group" in `references/aws.md`.
2. Resolve the encryption key for the current user.
3. Encrypt with the user's email in the filename. Use the multi-provider naming convention if the config has a `providers` array:
   ```bash
   USER_EMAIL=$(git config user.email)
   if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then
     # PROVIDER must already be set from Step 1 — validate but do not overwrite
     if [ -z "$PROVIDER" ] || [ "$PROVIDER" = "null" ]; then
       echo "ERROR: PROVIDER is not set — determine it from .cloud-config.json in Step 1."
       exit 1
     fi
     ENC_FILE=".cloud-credentials.${PROVIDER}.${USER_EMAIL}.enc"
   else
     ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   fi
   echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
     -pass stdin \
     -in credentials.json -out "$ENC_FILE"
   ```
   **Note:** In multi-provider mode, `PROVIDER` must be set to the provider being onboarded (e.g., `gcp`, `aws`, `azure`) before running this snippet. Step 1 determines the provider from `.cloud-config.json`.
4. **Delete the plaintext credentials immediately:**
   ```bash
   rm -f credentials.json
   ```
5. Commit the new encrypted credentials file.

## Step 4: Ensure SessionStart Hook Exists

Check if `.claude/settings.json` already contains a SessionStart hook for the provider's CLI. If not, add one following the "SessionStart Hook" instructions in the provider's reference file. Commit `.claude/settings.json` if it was created or modified.

## Step 5: Done

The bootstrap token is now spent. The user can now authenticate in future sessions using their own passphrase.
