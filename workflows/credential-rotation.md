# Credential Rotation

Use this when credentials need to be replaced (e.g., age warning, suspected compromise, policy requirement). This replaces the current user's encrypted key without affecting other team members.

1. Read `.cloud-config.json` to determine the provider. Read the provider reference file.
2. Ask the user for a bootstrap token (same as during setup).
3. **Delete the old key on the provider side:**
   - **GCP:** List keys (see "Key Management" in gcp.md), identify the current user's key, delete it.
   - **AWS:** Delete the current access key: `aws iam delete-access-key --user-name "claude-agent-${SANITIZED_EMAIL}" --access-key-id OLD_KEY_ID`
   - **Azure:** Remove the current client secret (see "Secret Management" in azure.md).
4. Create a **new key** using the same commands as the "Create Key" / "Create Access Key" / "Add Client Secret" section in the provider reference.
5. Re-encrypt with the user's passphrase. Use the multi-provider naming convention if the config has a `providers` array:
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
   echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
     -pass stdin \
     -in credentials.json -out "$ENC_FILE"
   rm -f credentials.json
   ```
   **Note:** `PROVIDER` is derived in step 1 when reading `.cloud-config.json`. In single-provider mode it comes from the top-level `provider` field; in multi-provider mode it is the specific provider whose credentials are being rotated.
6. Update `created_at` in `.cloud-config.json` to the current timestamp.
7. Commit the updated encrypted credentials file and `.cloud-config.json`.
