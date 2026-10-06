# Authenticate (Subsequent Sessions)

Run this every time you need cloud access and are not yet authenticated. The SessionStart hook normally handles this automatically, but this flow serves as a fallback.

1. Read `.cloud-config.json` to determine the provider.
2. **Credential age is checked per credential file**, not repo-wide, so one
   teammate rotating does not reset everyone's age. The check needs `$ENC_FILE`
   (resolved in step 6), so it runs in step 7 — once per provider/file — not here.
3. Ensure the provider's CLI is installed by running the installation script from the corresponding reference file. This is a safety net in case the SessionStart hook hasn't run yet.
4. Get the current user's email:
   ```bash
   USER_EMAIL=$(git config user.email)
   [ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
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
         :
       fi
     done
   else
     PROVIDER=$(jq -r .provider .cloud-config.json)
     ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   fi
   ```
   In multi-provider mode, repeat steps 7–9 for **each** provider that has a credential file for the current user.
7. For each resolved `$ENC_FILE`, first **warn on credential age** (per file, now
   that `$ENC_FILE` is known), then decrypt with restrictive permissions and
   guaranteed cleanup:
   ```bash
   # Per-file age: derive from the file's last git commit time, falling back to
   # the shared created_at only when git history is unavailable.
   COMMIT_TS=$(git log --follow --diff-filter=AM -1 --format=%ct -- "$ENC_FILE" 2>/dev/null)
   if [ -z "$COMMIT_TS" ]; then
     # Multi-provider configs keep created_at in each provider's entry
     COMMIT_TS=$(date -d "$(jq -r --arg p "$PROVIDER" '(if .providers then (.providers[] | select(.provider == $p) | .created_at) else .created_at end) // empty' .cloud-config.json)" +%s 2>/dev/null)
   fi
   if [ -n "$COMMIT_TS" ] && [ "$(( ( $(date +%s) - COMMIT_TS ) / 86400 ))" -gt 180 ]; then
     echo "NOTE: $PROVIDER credentials are over 180 days old — consider rotating (see Credential Rotation)."
   fi

   trap 'rm -f /tmp/credentials.json' EXIT
   # A failed run must not leave an earlier activation of this provider in this
   # container usable: log it out and drop what was persisted for the session,
   # as the SessionStart hooks do
   clear_prior() {
     case "$PROVIDER" in
       gcp)
         A=$(jq -r '.client_email // empty' /tmp/gcp-adc-credentials.json 2>/dev/null)
         [ -z "$A" ] || gcloud auth revoke "$A" >/dev/null 2>&1 || true
         rm -f /tmp/gcp-adc-credentials.json
         if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
           sed -i '/GOOGLE_APPLICATION_CREDENTIALS/d' "$CLAUDE_ENV_FILE"
           echo "unset GOOGLE_APPLICATION_CREDENTIALS" >> "$CLAUDE_ENV_FILE"
         fi ;;
       aws)
         # A profile or session token left selected would let later commands
         # authenticate as something else instead of failing
         unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_PROFILE AWS_SESSION_TOKEN
         if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
           sed -i '/^export AWS_ACCESS_KEY_ID=/d; /^export AWS_SECRET_ACCESS_KEY=/d; /^export AWS_DEFAULT_REGION=/d; /^export AWS_PROFILE=/d; /^export AWS_SESSION_TOKEN=/d' "$CLAUDE_ENV_FILE"
           echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_PROFILE AWS_SESSION_TOKEN" >> "$CLAUDE_ENV_FILE"
         fi ;;
       azure)
         command -v az >/dev/null 2>&1 && az logout >/dev/null 2>&1 || true ;;
     esac
   }
   if ! (umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
     -pass stdin \
     -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null); then
     echo "WARNING: Failed to decrypt $PROVIDER credentials — check your credentials key or .enc file integrity. Any earlier $PROVIDER login in this session is cleared."
     clear_prior
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
9. **Delete `/tmp/credentials.json` immediately after activation** (the `trap EXIT` ensures cleanup even on failure). This is only the temporary copy from step 7. For GCP, activation decrypts its own session copy to `/tmp/gcp-adc-credentials.json` for Python clients (`GOOGLE_APPLICATION_CREDENTIALS`); keep that one for the session.
10. **Verify credentials work** by running the smoke test command from the provider reference file (see "Verify (Smoke Test)" section). If the smoke test fails, inform the user that credentials may be expired or revoked and suggest re-running setup.
