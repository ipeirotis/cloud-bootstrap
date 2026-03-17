# Authenticate (Subsequent Sessions)

Run this every time you need cloud access and are not yet authenticated. The SessionStart hook normally handles this automatically, but this flow serves as a fallback.

1. Read `.cloud-config.json` to determine the provider.
2. **Check credential age:** If `created_at` exists in `.cloud-config.json`, calculate how old the credentials are. If older than **180 days**, warn the user:
   ```
   Your cloud credentials were created <N> days ago. Consider rotating
   them for security. See the "Credential Rotation" workflow.
   ```
   This is a warning only — do not block authentication.
3. Ensure the provider's CLI is installed by running the installation script from the corresponding reference file. This is a safety net in case the SessionStart hook hasn't run yet.
4. Get the current user's email:
   ```bash
   USER_EMAIL=$(git config user.email)
   ```
5. Read the corresponding provider reference file in this skill's directory.
6. Resolve the encryption key.
7. Decrypt the user's credentials:
   ```bash
   echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
     -pass stdin \
     -in ".cloud-credentials.${USER_EMAIL}.enc" -out /tmp/credentials.json
   ```
8. Activate using the provider-specific commands from the reference file.
9. **Delete `/tmp/credentials.json` immediately after activation.**
10. **Verify credentials work** by running the smoke test command from the provider reference file (see "Verify (Smoke Test)" section). If the smoke test fails, inform the user that credentials may be expired or revoked and suggest re-running setup.
