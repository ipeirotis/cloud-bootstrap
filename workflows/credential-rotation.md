# Credential Rotation

Use this when credentials need to be replaced (e.g., age warning, suspected compromise, policy requirement). This replaces the current user's encrypted key without affecting other team members.

1. Read `.cloud-config.json` to determine the provider. Read the provider reference file.
2. **Resolve the encryption key** (SKILL.md) and stop if it is missing, before anything changes on the provider side; then ask the user for a bootstrap token (same as during setup).

> **Order matters: create and verify the replacement BEFORE revoking the old key.**
> For routine rotations, never delete the current provider-side key first. If the
> create/encrypt/commit step then fails (bootstrap token expired, passphrase
> missing, provider error), the committed encrypted credential would point at a
> revoked key and lock the user out until they repeat privileged onboarding.
> **Exception:** for a suspected/known compromise, containment wins: capture
> `OLD_KEY_ID` (step 3), then **revoke it at once** (the provider-side delete in
> step 9), before creating the replacement, accepting the brief lockout. Then
> continue with steps 4–8.

3. **Record the OLD key identifier first**, before creating or overwriting anything. The old key id often lives only in the current credential material, so capture it now or it becomes unrecoverable once the `.enc` is replaced:
   - **GCP:** decrypt the existing `ENC_FILE` and read `OLD_KEY_ID=$(... | jq -r .private_key_id)` (or list keys via "Key Management" and note the current one).
   - **AWS:** `OLD_KEY_ID` is the existing `access_key_id` (decrypt the current `ENC_FILE` to read it). Also derive the user it belongs to now, since the compromise path revokes before step 4 runs (helpers from aws.md "IAM Names"):
     ```bash
     USER_PREFIX=$(aws_cfg iam_user_prefix); USER_PREFIX="${USER_PREFIX:-claude-agent}"
     IAM_USER=$(iam_user_name "$(git config user.email)" "$USER_PREFIX")
     ```
   - **Azure:** list the app's existing secret `keyId`s now (see "Secret Management") and note which one to remove.
   Save it as `OLD_KEY_ID` for the revoke step.
4. Create a **new key** using the same commands as the "Create Key" / "Create Access Key" / "Add Client Secret" section in the provider reference.
   - **AWS caveat:** the add-team-member snippet calls `aws iam create-user` first, but during rotation the user already exists, so that call errors. For an AWS rotation, **skip `create-user`/`add-user-to-group`** and only create a new access key for the existing user:
     ```bash
     # Same repo-scoped name as references/aws.md ("IAM Names"): define its
     # aws_cfg and iam_user_name helpers first
     USER_PREFIX=$(aws_cfg iam_user_prefix); USER_PREFIX="${USER_PREFIX:-claude-agent}"
     IAM_USER=$(iam_user_name "$(git config user.email)" "$USER_PREFIX")
     (umask 077 && aws iam create-access-key --user-name "$IAM_USER" > credentials.json)
     # then reformat (access_key_id/secret_access_key/region) as in aws.md
     ```
     (AWS allows up to 2 access keys per user, so the new key can be created before the old one is revoked in step 9.)
5. Verify the **new** key works before touching the old one. The provider smoke test alone is not enough: the CLI is still logged in as the old key (or the bootstrap admin), so it would pass without using the replacement. Activate `credentials.json` in an isolated config and confirm the caller identity:
   - **GCP** (a new key can take a minute or more to work, so retry with backoff before giving up; `PROJECT_ID`, `SA_EMAIL`, and `TOKEN` as in "Create Key"):
     ```bash
     NEW_KEY_ID=$(jq -r .private_key_id credentials.json)
     TMPCFG=$(mktemp -d); VERIFIED=""
     for delay in 0 10 20 40 80; do
       sleep "$delay"
       if env -u CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_CONFIG="$TMPCFG" gcloud auth activate-service-account --key-file=credentials.json 2>/dev/null \
          && env -u CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_CONFIG="$TMPCFG" gcloud auth print-access-token >/dev/null 2>&1; then
         VERIFIED=1; break
       fi
     done
     if [ -n "$VERIFIED" ]; then
       env -u CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_CONFIG="$TMPCFG" gcloud config get-value account
       rm -rf "$TMPCFG"
     else
       # Leave nothing behind: delete the unverified replacement key and its plaintext
       rm -rf "$TMPCFG"
       curl -sS --fail -X DELETE \
         "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys/$NEW_KEY_ID" \
         -H "Authorization: Bearer $TOKEN" >/dev/null \
         || echo "WARNING: could not delete replacement key $NEW_KEY_ID; delete it via Key Management."
       rm -f credentials.json
       echo "ERROR: the replacement key failed verification; nothing was encrypted and the old key was not revoked by this step."; exit 1
     fi
     ```
   - **AWS** (new keys can take a few seconds to propagate):
     ```bash
     env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
       AWS_ACCESS_KEY_ID="$(jq -r .access_key_id credentials.json)" \
       AWS_SECRET_ACCESS_KEY="$(jq -r .secret_access_key credentials.json)" \
       aws sts get-caller-identity --query Arn --output text   # must end in user/$IAM_USER
     ```
   - **Azure:**
     ```bash
     TMPCFG=$(mktemp -d)
     if AZURE_CONFIG_DIR="$TMPCFG" az login --service-principal \
          -u "$(jq -r .appId credentials.json)" -p "$(jq -r .password credentials.json)" \
          --tenant "$(jq -r .tenant credentials.json)" >/dev/null \
        && AZURE_CONFIG_DIR="$TMPCFG" az account show --query user.name -o tsv; then
       rm -rf "$TMPCFG"
     else
       rm -rf "$TMPCFG"; echo "ERROR: the replacement secret failed verification; do not encrypt it or revoke the old one."; exit 1
     fi
     ```
   Continue only if the reported identity is the expected service account, user, or app.
6. Re-encrypt with the user's passphrase. Use the multi-provider naming convention if the config has a `providers` array:
   ```bash
   USER_EMAIL=$(git config user.email)
   if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then
     # PROVIDER must already be set from step 1 (read from .cloud-config.json)
     if [ -z "$PROVIDER" ] || [ "$PROVIDER" = "null" ]; then
       echo "ERROR: Could not determine provider for credential filename."
       exit 1
     fi
     ENC_FILE=".cloud-credentials.${PROVIDER}.${USER_EMAIL}.enc"
   else
     PROVIDER=$(jq -r .provider .cloud-config.json 2>/dev/null)
     ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   fi
   # Encrypt to a private temp file in the same directory, prove it decrypts
   # to the new key, and only then replace ENC_FILE in one rename. A failed or
   # interrupted write never truncates the current credential, and the
   # plaintext is kept until the replacement is safely in place.
   TMP_ENC=$(umask 077 && mktemp "${ENC_FILE}.tmp.XXXXXX")
   if echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass stdin \
        -in credentials.json -out "$TMP_ENC" \
      && echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$TMP_ENC" \
        | cmp -s - credentials.json; then
     mv -f "$TMP_ENC" "$ENC_FILE" && rm -f credentials.json
   else
     rm -f "$TMP_ENC"
     echo "ERROR: re-encryption failed; $ENC_FILE and credentials.json are unchanged. Fix the cause and retry."
     exit 1
   fi
   ```
   **Note:** `PROVIDER` is derived in step 1 when reading `.cloud-config.json`. In single-provider mode it comes from the top-level `provider` field; in multi-provider mode it is the specific provider whose credentials are being rotated.
7. **Do not reset the shared top-level `created_at`** in `.cloud-config.json` — that field is repo-wide, so bumping it makes every other team member's still-old `.cloud-credentials.*.enc` look freshly rotated and suppresses their 180-day age warning. Credential age is tracked **per file** via each `.enc` file's git commit time (the Authenticate age check uses that), so committing the rotated file in the next step updates only this user's age. (If you maintain optional per-file age metadata, update only this credential's entry — never the shared timestamp.)
8. **GCP:** set this member's `key_ids` entry in `.cloud-config.json` to `NEW_KEY_ID` ("Record the key's owner" in gcp.md, with `KEY_ID="$NEW_KEY_ID"`). Commit the updated encrypted credentials file (and, for GCP, `.cloud-config.json`).
9. **Now revoke the OLD key on the provider side** using the `OLD_KEY_ID` captured in step 3 (only after the replacement is verified and committed):
   - **GCP:** delete `OLD_KEY_ID`, failing on any HTTP error so a rejected delete is not mistaken for a revoked key:
     ```bash
     [ -n "$OLD_KEY_ID" ] || { echo "ERROR: capture OLD_KEY_ID (step 3) first."; exit 1; }
     curl -sS --fail -X DELETE \
       "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys/$OLD_KEY_ID" \
       -H "Authorization: Bearer $TOKEN" \
       || { echo "ERROR: old key $OLD_KEY_ID is still active; retry with a fresh token."; exit 1; }
     ```
   - **AWS:** Delete the old access key, with `IAM_USER` as derived in step 3 (it must not be empty):
     ```bash
     [ -n "$IAM_USER" ] && [ -n "$OLD_KEY_ID" ] || { echo "ERROR: derive IAM_USER and OLD_KEY_ID (step 3) first."; exit 1; }
     aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$OLD_KEY_ID"
     ```
   - **Azure:** Remove the *previous* client secret (see "Secret Management" in azure.md).
