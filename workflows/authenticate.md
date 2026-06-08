# Authenticate (Subsequent Sessions)

Run this every time you need cloud access and are not yet authenticated. The SessionStart hook normally handles this automatically, but this flow serves as a fallback.

1. Read `.cloud-config.json` to determine the provider.
2. **Check credential age (per credential file):** Age is tracked per `.enc`
   file, not repo-wide, so one teammate rotating does not reset everyone's age.
   For the current user's encrypted credential file(s) (`$ENC_FILE`, resolved in
   step 6), derive age from the file's last git commit time, falling back to the
   shared `created_at` only when git history is unavailable:
   ```bash
   COMMIT_TS=$(git log -1 --format=%ct -- "$ENC_FILE" 2>/dev/null)
   if [ -z "$COMMIT_TS" ]; then
     COMMIT_TS=$(date -d "$(jq -r '.created_at // empty' .cloud-config.json)" +%s 2>/dev/null)
   fi
   if [ -n "$COMMIT_TS" ]; then
     AGE_DAYS=$(( ( $(date +%s) - COMMIT_TS ) / 86400 ))
   fi
   ```
   If older than **180 days**, warn the user:
   ```
   Your <provider> credentials are <N> days old. Consider rotating them for
   security. See the "Credential Rotation" workflow.
   ```
   This is a warning only — do not block authentication.
3. Ensure the provider's CLI is installed by running the installation script from the corresponding reference file. This is a safety net in case the SessionStart hook hasn't run yet.
4. Get the current user's email:
   ```bash
   USER_EMAIL=$(git config user.email)
   ```
5. Read the corresponding provider reference file in this skill's directory.
6. Resolve the encryption key and determine the credential file name:
   ```bash
   if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then
     # Multi-provider: iterate providers to find credential files for this user
     for PROVIDER in $(jq -r '.providers[].provider' .cloud-config.json); do
       ENC_FILE=".cloud-credentials.${PROVIDER}.${USER_EMAIL}.enc"
       if [ -f "$ENC_FILE" ]; then
         # Resolve key and run steps 7-9 for this provider, then continue loop
       fi
     done
   else
     PROVIDER=$(jq -r .provider .cloud-config.json)
     ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   fi
   ```
   In multi-provider mode, repeat steps 7–9 for **each** provider that has a credential file for the current user.
7. Decrypt the user's credentials with restrictive permissions and guaranteed cleanup:
   ```bash
   trap 'rm -f /tmp/credentials.json' EXIT
   if ! (umask 077 && echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
     -pass stdin \
     -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null); then
     echo "WARNING: Failed to decrypt $PROVIDER credentials — check your credentials key or .enc file integrity."
     # Multi-provider runs inside the for loop above (skip to next provider);
     # single-provider is a flat script (stop). `continue` outside a loop is a
     # no-op that returns success, so branch explicitly instead of relying on it.
     if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then
       continue
     else
       exit 1
     fi
   fi
   ```
8. Activate using the provider-specific commands from the reference file.
9. **Delete `/tmp/credentials.json` immediately after activation** (the `trap EXIT` ensures cleanup even on failure).
10. **Verify credentials work** by running the smoke test command from the provider reference file (see "Verify (Smoke Test)" section). If the smoke test fails, inform the user that credentials may be expired or revoked and suggest re-running setup.
