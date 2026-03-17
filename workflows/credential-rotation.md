# Credential Rotation

Use this when credentials need to be replaced (e.g., age warning, suspected compromise, policy requirement). This replaces the current user's encrypted key without affecting other team members.

1. Read `.cloud-config.json` to determine the provider. Read the provider reference file.
2. Ask the user for a bootstrap token (same as during setup).
3. **Delete the old key on the provider side:**
   - **GCP:** List keys (see "Key Management" in gcp.md), identify the current user's key, delete it.
   - **AWS:** Delete the current access key: `aws iam delete-access-key --user-name "claude-agent-${SANITIZED_EMAIL}" --access-key-id OLD_KEY_ID`
   - **Azure:** Remove the current client secret (see "Secret Management" in azure.md).
4. Create a **new key** using the same commands as the "Create Key" / "Create Access Key" / "Add Client Secret" section in the provider reference.
5. Re-encrypt with the user's passphrase:
   ```bash
   USER_EMAIL=$(git config user.email)
   echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
     -pass stdin \
     -in credentials.json -out ".cloud-credentials.${USER_EMAIL}.enc"
   rm -f credentials.json
   ```
6. Update `created_at` in `.cloud-config.json` to the current timestamp.
7. Commit the updated `.cloud-credentials.<email>.enc` and `.cloud-config.json`.
