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
> step 9, with `COMPROMISE=1`), before creating the replacement,
> accepting the brief lockout. Then continue with steps 4–8.

3. **Record the OLD key identifier first**, before creating or overwriting anything, and save it in `.cloud-config.json` (it is not secret). The old ID often lives only in the current credential, so once step 6 replaces the `.enc` it could not be recovered; saved under `rotating[<email>]` it survives fresh shells and is what step 8 queues for revocation and step 9 revokes.
   - **GCP:** the member's `key_ids` entry, or `private_key_id` of the decrypted current `ENC_FILE` (or list keys via "Key Management" and note the current one).
   - **AWS:** `access_key_id` of the decrypted current `ENC_FILE`.
   - **Azure:** `keyId` of the decrypted current `ENC_FILE` (credentials created by this version carry it); for older files, list the app's secrets ("Secret Management") and take this member's current one.
   ```bash
   USER_EMAIL=$(git config user.email)
   [ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
   # PROVIDER: the provider being rotated (required in multi-provider configs)
   PROVIDER="${PROVIDER:-$(jq -r '.provider // empty' .cloud-config.json)}"
   [ -n "$PROVIDER" ] || { echo "ERROR: set PROVIDER to the provider being rotated."; exit 1; }
   pcfg() { jq -r --arg p "$PROVIDER" --arg e "$USER_EMAIL" "(if .providers then (.providers[] | select(.provider == \$p)) else . end) | $1 // empty" .cloud-config.json; }
   [ -n "$OLD_KEY_ID" ] || { echo "ERROR: set OLD_KEY_ID to the key being replaced."; exit 1; }
   # An earlier, interrupted rotation may already have saved the key being
   # replaced. Never overwrite that record: after step 6 the .enc holds the
   # replacement, so re-reading OLD_KEY_ID from it would name the new key.
   EXISTING=$(pcfg '.rotating[$e]')
   if [ -n "$EXISTING" ] && [ "$EXISTING" != "$OLD_KEY_ID" ]; then
     echo "ERROR: an interrupted rotation already saved $EXISTING as the key being replaced; nothing changed."
     echo "If its replacement was encrypted and committed (step 6), resume at step 8. Otherwise revoke any unused new key (scripts/discard-credential.sh) and continue from step 4; rotating[$USER_EMAIL] still names the old key."
     exit 1
   fi
   jq --arg p "$PROVIDER" --arg e "$USER_EMAIL" --arg old "$OLD_KEY_ID" '
     def s: .rotating[$e] = $old | del(.rotated[$e]);
     if .providers then .providers |= map(if .provider == $p then s else . end) else s end' \
     .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json
   ```
   Commit `.cloud-config.json` now, so the record also survives a fresh checkout.
4. Create a **new key** using the same commands as the "Create Key" / "Create Access Key" / "Add Client Secret" section in the provider reference.
   - **AWS caveat:** the add-team-member snippet calls `aws iam create-user` first, but during rotation the user already exists, so that call errors. For an AWS rotation, **skip `create-user`/`add-user-to-group`** and only create a new access key for the existing user:
     ```bash
     # Same repo-scoped name as references/aws.md ("IAM Names"): define its
     # aws_cfg and iam_user_name helpers first
     USER_PREFIX=$(aws_cfg iam_user_prefix); USER_PREFIX="${USER_PREFIX:-claude-agent}"
     IAM_USER=$(iam_user_name "$(git config user.email)" "$USER_PREFIX")
     # The bootstrap credentials must belong to this repo's account, or the key
     # would be created for a same-named user elsewhere
     AWS_ACCOUNT_ID=$(aws_cfg project_id)
     CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
       || { echo "ERROR: could not identify the bootstrap credentials' account; nothing created."; exit 1; }
     [ -n "$AWS_ACCOUNT_ID" ] && [ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
       || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not ${AWS_ACCOUNT_ID:-the configured one}; nothing created."; exit 1; }
     # AWS allows two access keys per user: the current one plus the new one.
     # Old keys still queued in revoke_pending take those slots, so delete them
     # first (step 9 without COMPROMISE: it never touches the current key)
     NKEYS=$(aws iam list-access-keys --user-name "$IAM_USER" --query 'length(AccessKeyMetadata)' --output text) \
       || { echo "ERROR: could not list $IAM_USER's keys; nothing created."; exit 1; }
     [ "$NKEYS" -lt 2 ] || { echo "ERROR: $IAM_USER already has $NKEYS keys: run step 9 to delete the keys in revoke_pending first; nothing created."; exit 1; }
     (umask 077 && aws iam create-access-key --user-name "$IAM_USER" > credentials.json)
     # then reformat (access_key_id/secret_access_key/region) as in aws.md
     ```
     (AWS allows up to 2 access keys per user, so the new key can be created before the old one is revoked in step 9.)
5. Verify the **new** key works before touching the old one. The provider smoke test alone is not enough: the CLI is still logged in as the old key (or the bootstrap admin), so it would pass without using the replacement. Activate `credentials.json` in an isolated config and confirm the caller identity:
   - **GCP** (a new key can take a minute or more to work, so retry with backoff before giving up; `TOKEN` is the bootstrap token):
     ```bash
     PROJECT_ID="${PROJECT_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)}"
     SA_EMAIL="${SA_EMAIL:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
     [ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: could not resolve the GCP project and service account from .cloud-config.json."; exit 1; }
     NEW_KEY_ID=$(jq -r .private_key_id credentials.json)
     TMPCFG=$(mktemp -d) && [ -d "$TMPCFG" ] \
       || { echo "ERROR: could not create an isolated config directory; nothing verified, run this step again."; exit 1; }
     VERIFIED=""
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
       # Leave nothing behind: revoke the unverified replacement, delete its plaintext
       rm -rf "$TMPCFG"
       TOKEN="${TOKEN:-}" GRAPH_TOKEN="${GRAPH_TOKEN:-}" PROJECT_ID="${PROJECT_ID:-}" SA_EMAIL="${SA_EMAIL:-}" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh gcp
       echo "ERROR: the replacement key failed verification; nothing was encrypted and the old key was not revoked by this step."; exit 1
     fi
     ```
   - **AWS** (new keys can take a few seconds to propagate, so retry with backoff; on final failure delete the new key, or the next attempt hits the two-key limit):
     ```bash
     NEW_KEY_ID=$(jq -r .access_key_id credentials.json)
     # The replacement must belong to this member's user in this repo's
     # account: derive both from the config and the email (works in a fresh
     # shell), never from the key itself, or any stale or copied key would pass.
     # Same naming rule as references/aws.md ("IAM Names").
     USER_EMAIL=$(git config user.email)
     [ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
     acfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"aws\")) else . end) | .$1 // empty" .cloud-config.json; }
     ACCOUNT=$(acfg project_id); PREFIX=$(acfg iam_user_prefix); PREFIX="${PREFIX:-claude-agent}"
     H=$(printf '%s' "$USER_EMAIL" | sha256sum | cut -c1-8)
     if [ "$PREFIX" = "claude-agent" ]; then
       WANT_USER="$PREFIX-$(printf '%s' "$USER_EMAIL" | sed 's/[^A-Za-z0-9+=,_-]/-/g')"
     else
       WANT_USER="$PREFIX-$(printf '%s' "$USER_EMAIL" | sed 's/[^A-Za-z0-9+=,.@_-]/-/g')"
       [ "$WANT_USER" = "$PREFIX-$USER_EMAIL" ] || WANT_USER="${WANT_USER:0:55}-$H"
     fi
     [ ${#WANT_USER} -le 64 ] || WANT_USER="${WANT_USER:0:55}-$H"
     # The key's owner and the caller ARN, from AWS itself. Both lookups are
     # retried: either can fail transiently while the new key propagates
     KEY_OWNER=""; ARN=""
     for delay in 0 5 10 20 40; do
       sleep "$delay"
       [ -n "$KEY_OWNER" ] || KEY_OWNER=$(aws iam get-access-key-last-used --access-key-id "$NEW_KEY_ID" \
         --query UserName --output text 2>/dev/null) || KEY_OWNER=""
       [ -n "$ARN" ] || ARN=$(env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
         AWS_ACCESS_KEY_ID="$NEW_KEY_ID" \
         AWS_SECRET_ACCESS_KEY="$(jq -r .secret_access_key credentials.json)" \
         aws sts get-caller-identity --query Arn --output text 2>/dev/null) || ARN=""
       [ -n "$KEY_OWNER" ] && [ -n "$ARN" ] && break
     done
     if [ -n "$ACCOUNT" ] && [ "${ARN#arn:*:}" = "iam::$ACCOUNT:user/$WANT_USER" ] && [ "$KEY_OWNER" = "$WANT_USER" ]; then
       echo "$ARN"
     else
       TOKEN="${TOKEN:-}" GRAPH_TOKEN="${GRAPH_TOKEN:-}" PROJECT_ID="${PROJECT_ID:-}" SA_EMAIL="${SA_EMAIL:-}" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh aws key
       echo "ERROR: the replacement key failed verification (got '$ARN'); nothing was encrypted."; exit 1
     fi
     ```
   - **Azure** (on failure remove the new secret so no live, untracked secret is left):
     ```bash
     TMPCFG=$(mktemp -d) && [ -d "$TMPCFG" ] \
       || { echo "ERROR: could not create an isolated config directory; nothing verified, run this step again."; exit 1; }
     if AZURE_CONFIG_DIR="$TMPCFG" az login --service-principal \
          -u "$(jq -r .appId credentials.json)" -p "$(jq -r .password credentials.json)" \
          --tenant "$(jq -r .tenant credentials.json)" >/dev/null \
        && AZURE_CONFIG_DIR="$TMPCFG" az account show --query user.name -o tsv; then
       rm -rf "$TMPCFG"
     else
       rm -rf "$TMPCFG"
       # Re-resolves the app and the new secret itself (works in a fresh shell)
       TOKEN="${TOKEN:-}" GRAPH_TOKEN="${GRAPH_TOKEN:-}" PROJECT_ID="${PROJECT_ID:-}" SA_EMAIL="${SA_EMAIL:-}" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh azure
       echo "ERROR: the replacement secret failed verification; nothing was encrypted."; exit 1
     fi
     ```
   Continue only if the reported identity is the expected service account, user, or app.
6. Re-encrypt with the user's passphrase. Use the multi-provider naming convention if the config has a `providers` array:
   ```bash
   USER_EMAIL=$(git config user.email)
   [ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
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
   # Fresh shell: resolve the passphrase here (as step 2 does) and require it;
   # an empty passphrase would produce a file the configured key cannot open
   case "$PROVIDER" in gcp) KVAR=GCP_CREDENTIALS_KEY ;; aws) KVAR=AWS_CREDENTIALS_KEY ;; azure) KVAR=AZURE_CREDENTIALS_KEY ;; esac
   KEY="${KEY:-${!KVAR:-${CLOUD_CREDENTIALS_KEY:-}}}"
   [ -n "$KEY" ] || { echo "ERROR: no passphrase for $PROVIDER; set ${KVAR:-CLOUD_CREDENTIALS_KEY} and re-run this step."; exit 1; }
   # Encrypt to a private temp file in the same directory, prove it decrypts
   # to the new key, and only then replace ENC_FILE in one rename. A failed
   # write never truncates the current credential; on failure the replacement
   # is revoked and its plaintext deleted, so nothing is stranded. On success
   # credentials.json stays until step 8 has recorded the swap: if the run is
   # interrupted in between (even in another shell), the next session finds it
   # and recovers ("Recovering an Interrupted Run" in SKILL.md).
   TMP_ENC=$(umask 077 && mktemp "${ENC_FILE}.tmp.XXXXXX")
   if printf '%s\n' "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass stdin \
        -in credentials.json -out "$TMP_ENC" \
      && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$TMP_ENC" \
        | cmp -s - credentials.json \
      && mv -f "$TMP_ENC" "$ENC_FILE"; then
     echo "Encrypted to $ENC_FILE; continue with steps 7 and 8."
   else
     rm -f "$TMP_ENC"
     echo "ERROR: re-encryption failed; $ENC_FILE is unchanged. Revoking the replacement; retry the rotation from step 4."
     TOKEN="${TOKEN:-}" GRAPH_TOKEN="${GRAPH_TOKEN:-}" PROJECT_ID="${PROJECT_ID:-}" SA_EMAIL="${SA_EMAIL:-}" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh "$PROVIDER" key
     exit 1
   fi
   ```
   **Note:** `PROVIDER` is derived in step 1 when reading `.cloud-config.json`. In single-provider mode it comes from the top-level `provider` field; in multi-provider mode it is the specific provider whose credentials are being rotated.
7. **Do not reset the shared top-level `created_at`** in `.cloud-config.json` — that field is repo-wide, so bumping it makes every other team member's still-old `.cloud-credentials.*.enc` look freshly rotated and suppresses their 180-day age warning. Credential age is tracked **per file** via each `.enc` file's git commit time (the Authenticate age check uses that), so committing the rotated file in the next step updates only this user's age. (If you maintain optional per-file age metadata, update only this credential's entry — never the shared timestamp.)
8. Record the swap in `.cloud-config.json`: move the old ID from `rotating` (step 3) to the member's `revoke_pending` list, which step 9 works through, and for GCP and Azure point `key_ids` at the new key or secret. The list keeps every earlier ID still awaiting deletion, so a second rotation never overwrites one. (In the compromise path step 9 has already revoked the old key and recorded that as `revoked_early`, so nothing is queued.)
   ```bash
   USER_EMAIL=$(git config user.email)
   [ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
   # PROVIDER: the provider being rotated (required in multi-provider configs)
   PROVIDER="${PROVIDER:-$(jq -r '.provider // empty' .cloud-config.json)}"
   [ -n "$PROVIDER" ] || { echo "ERROR: set PROVIDER to the provider being rotated."; exit 1; }
   pcfg() { jq -r --arg p "$PROVIDER" --arg e "$USER_EMAIL" "(if .providers then (.providers[] | select(.provider == \$p)) else . end) | $1 // empty" .cloud-config.json; }
   # Fresh shell: resolve the passphrase and file as steps 2 and 6 do
   case "$PROVIDER" in gcp) KVAR=GCP_CREDENTIALS_KEY ;; aws) KVAR=AWS_CREDENTIALS_KEY ;; azure) KVAR=AZURE_CREDENTIALS_KEY ;; esac
   KEY="${KEY:-${!KVAR:-${CLOUD_CREDENTIALS_KEY:-}}}"
   [ -n "$KEY" ] || { echo "ERROR: no passphrase for $PROVIDER; set $KVAR and re-run this step."; exit 1; }
   if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then
     ENC_FILE=".cloud-credentials.${PROVIDER}.${USER_EMAIL}.enc"
   else
     ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   fi
   # The new key's ID, always read back from the re-encrypted file: a NEW_KEY_ID
   # left in the shell by another run must not be recorded in its place
   FILE_KEY_ID=$(printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$ENC_FILE" 2>/dev/null \
     | jq -r '.private_key_id // .access_key_id // .keyId // empty')
   if [ -n "${NEW_KEY_ID:-}" ] && [ "$NEW_KEY_ID" != "$FILE_KEY_ID" ]; then
     echo "ERROR: NEW_KEY_ID is $NEW_KEY_ID, but $ENC_FILE holds ${FILE_KEY_ID:-no readable key}; nothing recorded. Unset NEW_KEY_ID."; exit 1
   fi
   NEW_KEY_ID="$FILE_KEY_ID"
   # Every provider needs it: an unreadable replacement must never let the old,
   # working key be queued for revocation
   if [ -z "$NEW_KEY_ID" ]; then
     echo "ERROR: could not read the new key ID from $ENC_FILE; nothing recorded."; exit 1
   fi
   # A rerun after this step already succeeded (before the commit): rotating is
   # gone and the old ID is queued (or, GCP/Azure, key_ids names the new key)
   if [ -z "${OLD_KEY_ID:-}" ] && [ -z "$(pcfg '.rotating[$e]')" ] && [ -z "$(pcfg '.revoked_early[$e]')" ] \
      && { [ -n "$(pcfg '(.revoke_pending[$e] // []) | if type == "string" then . else .[] end')" ] \
           || { [ "$PROVIDER" != aws ] && [ "$(pcfg '.key_ids[$e]')" = "$NEW_KEY_ID" ]; } \
           || { [ "$PROVIDER" = aws ] && [ "$(pcfg '.rotated[$e]')" = "$NEW_KEY_ID" ]; }; }; then
     echo "The swap is already recorded; commit $ENC_FILE and .cloud-config.json, then delete credentials.json and continue with step 9."
     exit 0
   fi
   OLD_KEY_ID="${OLD_KEY_ID:-$(pcfg '.rotating[$e]')}"
   [ "$PROVIDER" != aws ] && OLD_KEY_ID="${OLD_KEY_ID:-$(pcfg '.key_ids[$e]')}"
   [ -n "$(pcfg '.revoked_early[$e]')" ] && OLD_KEY_REVOKED=1
   [ "${OLD_KEY_REVOKED:-}" = 1 ] && OLD_KEY_ID=""     # revoked early (compromise path)
   [ -n "$NEW_KEY_ID" ] && [ "$OLD_KEY_ID" = "$NEW_KEY_ID" ] && OLD_KEY_ID=""   # step 8 already ran
   # Never drop the record of the key being replaced: stop unless it is known
   # or was already revoked
   if [ -z "$OLD_KEY_ID" ] && [ "${OLD_KEY_REVOKED:-}" != 1 ]; then
     echo "ERROR: no old key ID known; nothing changed. Set OLD_KEY_ID to this member's previous key (or OLD_KEY_REVOKED=1 if it is already deleted) and re-run this step."
     exit 1
   fi
   jq --arg p "$PROVIDER" --arg e "$USER_EMAIL" --arg new "${NEW_KEY_ID:-}" --arg old "${OLD_KEY_ID:-}" '
     # AWS keeps no key_ids: after a compromise rotation (nothing queued) only
     # "rotated" shows that this step already ran, for a rerun to recognize
     def upd: (if $p != "aws" and $new != "" then .key_ids[$e] = $new else . end)
       | (if $p == "aws" and $old == "" and $new != "" then .rotated[$e] = $new else del(.rotated[$e]) end)
       | del(.rotating[$e]) | del(.revoked_early[$e])
       | if $old != "" then .revoke_pending[$e] = (((.revoke_pending[$e] // []) | if type == "string" then [.] else . end) + [$old] | unique) else . end;
     if .providers then .providers |= map(if .provider == $p then upd else . end) else upd end' \
     .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
     || { echo "ERROR: could not update .cloud-config.json; credentials.json is kept, re-run this step."; exit 1; }
   ```
   Commit the updated encrypted credentials file together with `.cloud-config.json`, and only then delete the plaintext (`rm -f credentials.json`): until the commit, it is what lets an interrupted run be finished.
9. **Now revoke the OLD key on the provider side** (only after the replacement is verified and committed). The snippet deletes every ID in the member's `revoke_pending` list (step 8 queued the old key there) and clears each record only once the provider confirms the key is gone (a key that no longer exists counts as gone). In the compromise path (step 9 run before step 4) set `COMPROMISE=1`, so the ID saved in step 3 (`rotating`, or for GCP and Azure the current `key_ids` entry) is revoked too, even from a fresh shell; never set it after step 8, when `key_ids` names the new key. It needs the bootstrap credentials: `TOKEN` (GCP), the AWS bootstrap keys, or `GRAPH_TOKEN` (Azure).
   ```bash
   USER_EMAIL=$(git config user.email)
   [ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
   # PROVIDER: the provider being rotated (required in multi-provider configs)
   PROVIDER="${PROVIDER:-$(jq -r '.provider // empty' .cloud-config.json)}"
   [ -n "$PROVIDER" ] || { echo "ERROR: set PROVIDER to the provider being rotated."; exit 1; }
   pcfg() { jq -r --arg p "$PROVIDER" --arg e "$USER_EMAIL" "(if .providers then (.providers[] | select(.provider == \$p)) else . end) | $1 // empty" .cloud-config.json; }
   # Only queued IDs (and, with COMPROMISE, the key saved in step 3): never a
   # shell's OLD_KEY_ID, which before step 8 is the current, working key (step 4
   # runs this step early to free AWS key slots)
   IDS="$(pcfg '((.revoke_pending[$e] // []) | if type == "string" then [.] else . end) | .[]')"
   if [ "${COMPROMISE:-}" = 1 ]; then
     IDS="$IDS $(pcfg '.rotating[$e]')"
     [ "$PROVIDER" != aws ] && IDS="$IDS $(pcfg '.key_ids[$e]')"
   fi
   IDS=$(printf '%s\n' $IDS | sort -u)
   [ -n "$IDS" ] || { echo "ERROR: nothing to revoke (no revoke_pending entry; before step 4 set COMPROMISE=1)."; exit 1; }
   case "$PROVIDER" in
     aws)
       # A key lookup in the wrong account reports NoSuchEntity, which would
       # clear the record of a key still live in this repo's account
       AWS_ACCOUNT_ID=$(pcfg .project_id)
       CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
         || { echo "ERROR: could not identify the bootstrap credentials' account; nothing revoked."; exit 1; }
       [ -n "$AWS_ACCOUNT_ID" ] && [ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
         || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not ${AWS_ACCOUNT_ID:-the configured one}; nothing revoked."; exit 1; }
       # Only this member's keys: a mistyped or stale ID could name a teammate's.
       # Same naming rule as references/aws.md ("IAM Names").
       PREFIX=$(pcfg .iam_user_prefix); PREFIX="${PREFIX:-claude-agent}"
       H=$(printf '%s' "$USER_EMAIL" | sha256sum | cut -c1-8)
       if [ "$PREFIX" = "claude-agent" ]; then
         WANT_USER="$PREFIX-$(printf '%s' "$USER_EMAIL" | sed 's/[^A-Za-z0-9+=,_-]/-/g')"
       else
         WANT_USER="$PREFIX-$(printf '%s' "$USER_EMAIL" | sed 's/[^A-Za-z0-9+=,.@_-]/-/g')"
         [ "$WANT_USER" = "$PREFIX-$USER_EMAIL" ] || WANT_USER="${WANT_USER:0:55}-$H"
       fi
       [ ${#WANT_USER} -le 64 ] || WANT_USER="${WANT_USER:0:55}-$H" ;;
     gcp)
       PROJECT_ID=$(pcfg .project_id); SA_EMAIL=$(pcfg .service_account)
       [ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: no GCP project/service account in config."; exit 1; } ;;
     azure)
       APP_ID=$(pcfg .service_account)
       OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
         --data-urlencode "\$filter=appId eq '$APP_ID'" \
         -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
       [ -n "$OBJECT_ID" ] || { echo "ERROR: could not resolve the Azure application for $APP_ID."; exit 1; } ;;
   esac
   revoke() {   # $1 = key ID; succeeds once the key is gone
     case "$PROVIDER" in
       gcp)
         # A key created moments ago can read as missing (404) for a minute
         # or more: count 404 as gone only once it persists across retries
         for DELAY in 0 20 40 60; do
           sleep "$DELAY"
           HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
             "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys/$1" \
             -H "Authorization: Bearer $TOKEN")
           [ "$HTTP" = 404 ] || break
         done
         [ "$HTTP" = 200 ] || { [ "$HTTP" = 404 ] && echo "Key $1 no longer exists; clearing its record."; } ;;
       aws)
         # The key's owner, from AWS itself; NoSuchEntity means it is already gone
         if OUT=$(aws iam get-access-key-last-used --access-key-id "$1" --query UserName --output text 2>&1); then
           [ "$OUT" = "$WANT_USER" ] || { echo "ERROR: key $1 belongs to $OUT, not $WANT_USER; not revoking it."; return 1; }
           aws iam delete-access-key --user-name "$OUT" --access-key-id "$1"
         else
           printf '%s' "$OUT" | grep -q NoSuchEntity && echo "Key $1 no longer exists; clearing its record."
         fi ;;
       azure)
         HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
           "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/removePassword" \
           -H "Authorization: Bearer $GRAPH_TOKEN" -H "Content-Type: application/json" \
           -d "{\"keyId\": \"$1\"}")
         # Not 204: gone anyway if the app no longer lists it (lost response, earlier attempt)
         [ "$HTTP" = 204 ] || { R=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
             -H "Authorization: Bearer $GRAPH_TOKEN") \
           && printf '%s' "$R" | jq -e --arg k "$1" 'all(.passwordCredentials[]; .keyId != $k)' >/dev/null \
           && echo "Secret $1 no longer exists; clearing its record."; } ;;
     esac
   }
   FAILED=""; UNRECORDED=""
   for ID in $IDS; do
     revoke "$ID" || { FAILED="$FAILED $ID"; continue; }
     # Gone: drop it from revoke_pending; if rotating or key_ids still names it
     # (compromise path, before the replacement exists), record revoked_early so
     # a later step 8, even in a fresh shell, knows the old key is gone
     jq --arg p "$PROVIDER" --arg e "$USER_EMAIL" --arg id "$ID" '
       def clr: (if .revoke_pending[$e] then .revoke_pending[$e] = ((.revoke_pending[$e] | if type == "string" then [.] else . end) - [$id]) else . end)
         | (if .revoke_pending[$e] == [] then del(.revoke_pending[$e]) else . end)
         | (if .rotating[$e] == $id then del(.rotating[$e]) | .revoked_early[$e] = $id else . end)
         | (if .key_ids[$e] == $id then del(.key_ids[$e]) | .revoked_early[$e] = $id else . end);
       if .providers then .providers |= map(if .provider == $p then clr else . end) else clr end' \
       .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
       || UNRECORDED="$UNRECORDED $ID"
   done
   [ -z "$UNRECORDED" ] || echo "ERROR: revoked, but .cloud-config.json could not be updated for:$UNRECORDED. Remove them from revoke_pending by hand (a retry also clears them: a missing key counts as gone)."
   [ -z "$FAILED" ] || echo "ERROR: still active, kept in config for a retry with fresh bootstrap credentials:$FAILED"
   [ -z "$FAILED$UNRECORDED" ] || exit 1
   # Compromise path: the old key is gone, so a later step 8 in this shell
   # queues nothing. Not when step 4 ran this early to free AWS key slots:
   # the current key is still live and step 8 must queue it
   if [ "${COMPROMISE:-}" = 1 ]; then unset OLD_KEY_ID; OLD_KEY_REVOKED=1; fi
   unset COMPROMISE
   ```
   Commit `.cloud-config.json`.
