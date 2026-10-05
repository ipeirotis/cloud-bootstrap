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

0. **Resolve the encryption key for the current user first** (SKILL.md), before creating anything on the provider side. If it is missing, stop and ask the user to set it; never create a key you cannot encrypt.
1. Create the new member's credential:
   - **GCP / Azure:** create a **new key** (GCP) or client secret (Azure) for the **existing** service account or app (do NOT create a new one). See the "Add Key for Existing Service Account" / "Add Client Secret" section in the provider reference.
   - **AWS:** the configured `service_account` is the shared IAM **group**, and access keys belong to users, not groups. Create a **new IAM user for this member in the existing group**, then its access key, following "Add Team Member: Create New User in Existing Group" in `references/aws.md`.
2. Use the encryption key resolved in step 0.
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
     PROVIDER=$(jq -r .provider .cloud-config.json)
     ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   fi
   if ! echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass stdin \
        -in credentials.json -out "$ENC_FILE"; then
     # The provider-side credential is live but unusable: revoke it, then drop
     # the plaintext, so nothing active and untracked is left behind. If a
     # revocation fails, its non-secret ID goes to cloud-revoke-pending.txt
     # (untracked) so it can still be found and removed by hand.
     rm -f "$ENC_FILE"
     echo "ERROR: encryption failed; revoking the new $PROVIDER credential."
     pending() { echo "$(date -u +%FT%TZ) $PROVIDER $*" >> cloud-revoke-pending.txt; echo "WARNING: could not revoke $*; recorded in cloud-revoke-pending.txt."; }
     case "$PROVIDER" in
       gcp)
         KEY_ID=$(jq -r .private_key_id credentials.json)
         PROJECT_ID=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp")) else . end) | .project_id // empty' .cloud-config.json)
         SA_EMAIL=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp")) else . end) | .service_account // empty' .cloud-config.json)
         curl -sS --fail -X DELETE \
           "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys/$KEY_ID" \
           -H "Authorization: Bearer $TOKEN" >/dev/null \
           || pending "key $KEY_ID of $SA_EMAIL (delete via Key Management in references/gcp.md)" ;;
       azure)
         # OBJECT_ID and NEW_SECRET_KEY_ID were printed by Add Client Secret
         STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
           "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/removePassword" \
           -H "Authorization: Bearer $GRAPH_TOKEN" -H "Content-Type: application/json" \
           -d "{\"keyId\": \"$NEW_SECRET_KEY_ID\"}")
         [ "$STATUS" = "204" ] \
           || pending "secret $NEW_SECRET_KEY_ID of app object $OBJECT_ID (HTTP $STATUS; remove via Secret Management in references/azure.md)" ;;
       aws)
         # Find the user from the new key itself, then remove keys, groups, user
         AK=$(jq -r '.access_key_id // .AccessKey.AccessKeyId // empty' credentials.json)
         U=$(aws iam get-access-key-last-used --access-key-id "$AK" --query UserName --output text 2>/dev/null)
         if [ -n "$U" ] && [ "$U" != "None" ]; then
           for k in $(aws iam list-access-keys --user-name "$U" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
             aws iam delete-access-key --user-name "$U" --access-key-id "$k"
           done
           for g in $(aws iam list-groups-for-user --user-name "$U" --query 'Groups[].GroupName' --output text); do
             aws iam remove-user-from-group --group-name "$g" --user-name "$U"
           done
           aws iam delete-user --user-name "$U" || pending "IAM user $U (access key $AK)"
         else
           pending "access key $AK (its IAM user could not be looked up)"
         fi ;;
     esac
     # Key IDs are printed above; the plaintext secret is never kept
     rm -f credentials.json
     exit 1
   fi
   ```
   **Note:** In multi-provider mode, `PROVIDER` must be set to the provider being onboarded (e.g., `gcp`, `aws`, `azure`) before running this snippet. Step 1 determines the provider from `.cloud-config.json`.
4. **GCP:** record the new key's ID under `key_ids` in `.cloud-config.json` ("Record the key's owner" in `references/gcp.md`), so the key can be found when this member leaves. Run it before the next step: it reads the ID from `credentials.json` (or, failing that, from the encrypted file).
5. **Delete the plaintext credentials immediately:**
   ```bash
   rm -f credentials.json
   ```
6. Commit the new encrypted credentials file (and, for GCP, `.cloud-config.json`).

## Step 4: Ensure SessionStart Hook Exists

Check if `.claude/settings.json` already contains a SessionStart hook for the provider's CLI. If not, add one following the "SessionStart Hook" instructions in the provider's reference file. Commit `.claude/settings.json` if it was created or modified.

## Step 5: Done

The bootstrap token is now spent. The user can now authenticate in future sessions using their own passphrase.
