# GCP Reference

## User Prerequisites (First-Time Setup)

The user's GCP account needs **Owner**, or **Service Account Admin + Service Account Key Admin + Project IAM Admin**, on the project. Service Account Admin alone cannot create keys: `iam.serviceAccountKeys.create` is in Service Account Key Admin.

## Team Member Prerequisites (Adding to Existing Setup)

The user's GCP account needs **Service Account Key Admin** on the project (or on the specific service account). This is a narrower permission than what the first user needs.

## Key Limits

GCP allows **10 keys per service account**. Keep one slot free: Credential Rotation creates and verifies the replacement before deleting the old key, so a member can rotate only while the account has fewer than 10 keys. In practice that is **9 team members** per service account (fewer while old keys await revocation in `revoke_pending`). Before adding a member or rotating, count the keys ("Key Management" below) and delete unused ones; if all 10 are in use, rotate by the compromise ordering (revoke first, accepting a brief lockout) or create a second service account.

## Bootstrap Token Command

Tell the user to run in [Google Cloud Shell](https://console.cloud.google.com) (click the ">_" terminal icon in the Cloud Console) or on their local machine if they have `gcloud` installed:

```bash
gcloud config set project PROJECT_ID
gcloud auth print-access-token
```

This produces a token valid for ~1 hour.

## CLI Installation

The Claude Code on the Web sandbox does not have `gcloud` pre-installed. Use this script to install it:

```bash
if ! command -v gcloud &> /dev/null; then
  # Check common install paths first
  for dir in /home/user/google-cloud-sdk/bin /usr/lib/google-cloud-sdk/bin /usr/local/google-cloud-sdk/bin; do
    if [ -x "$dir/gcloud" ]; then export PATH="$dir:$PATH"; break; fi
  done
fi
if ! command -v gcloud &> /dev/null; then
  INSTALLER=$(curl -sSL https://sdk.cloud.google.com 2>/dev/null) || true
  if [ -z "$INSTALLER" ] || ! echo "$INSTALLER" | bash -s -- --disable-prompts --install-dir=/home/user; then
    echo "WARNING: gcloud SDK install failed."
  else
    export PATH="/home/user/google-cloud-sdk/bin:$PATH"
  fi
fi
```

### SessionStart Hook

After setup completes, create a SessionStart hook that installs the CLI **and** authenticates automatically. Create `.claude/hooks/cloud-auth.sh`:

```bash
#!/bin/bash
set -e

# Claude Code on the Web only: each session is its own container. On a shared
# local machine the fixed key path and gcloud's active account would leak
# between concurrent sessions, so local users keep their own gcloud login.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then exit 0; fi
# Hooks run in the session's current directory, which may be a subdirectory
cd "${CLAUDE_PROJECT_DIR:-.}"

# --- Auto-authenticate if credentials exist ---
CONFIG=".cloud-config.json"
if [ ! -f "$CONFIG" ]; then exit 0; fi

PROVIDER=$(jq -r .provider "$CONFIG" 2>/dev/null) || exit 0
if [ "$PROVIDER" != "gcp" ]; then exit 0; fi

# Claude Code on the Web can preset CLOUDSDK_AUTH_ACCESS_TOKEN, which outranks
# the activated service account in gcloud's credential order. Clear it for this
# script and the whole session before any early exit.
unset CLOUDSDK_AUTH_ACCESS_TOKEN
if [ -n "$CLAUDE_ENV_FILE" ]; then
  grep -qxF "unset CLOUDSDK_AUTH_ACCESS_TOKEN" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "unset CLOUDSDK_AUTH_ACCESS_TOKEN" >> "$CLAUDE_ENV_FILE"
fi

USER_EMAIL=$(git config user.email 2>/dev/null || true)
ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
if [ -z "$USER_EMAIL" ] || [ ! -f "$ENC_FILE" ]; then exit 0; fi

KEY="${GCP_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}"
if [ -z "$KEY" ]; then exit 0; fi

# --- Per-file credential age, as in the Authenticate workflow ---
COMMIT_TS=$(git log --follow --diff-filter=AM -1 --format=%ct -- "$ENC_FILE" 2>/dev/null || true)
if [ -z "$COMMIT_TS" ]; then
  COMMIT_TS=$(date -d "$(jq -r '.created_at // empty' "$CONFIG")" +%s 2>/dev/null || true)
fi
if [ -n "$COMMIT_TS" ] && [ "$(( ( $(date +%s) - COMMIT_TS ) / 86400 ))" -gt 180 ]; then
  echo "NOTE: GCP credentials in $ENC_FILE are over 180 days old — consider rotating (see Credential Rotation)."
fi

# --- Install gcloud if missing ---
if ! command -v gcloud &> /dev/null; then
  for dir in /home/user/google-cloud-sdk/bin /usr/lib/google-cloud-sdk/bin /usr/local/google-cloud-sdk/bin; do
    if [ -x "$dir/gcloud" ]; then export PATH="$dir:$PATH"; break; fi
  done
fi
if ! command -v gcloud &> /dev/null; then
  INSTALLER=$(curl -sSL https://sdk.cloud.google.com 2>/dev/null) || true
  if [ -z "$INSTALLER" ] || ! echo "$INSTALLER" | bash -s -- --disable-prompts --install-dir=/home/user; then
    echo "WARNING: gcloud SDK install failed — skipping GCP auth."
    exit 0
  fi
  export PATH="/home/user/google-cloud-sdk/bin:$PATH"
fi

# --- Decrypt credentials to a session-stable, private location ---
# The decrypted key must persist for the whole session so that Python Google
# client libraries (which read GOOGLE_APPLICATION_CREDENTIALS / ADC, not the
# gcloud CLI auth store) can authenticate. It lives only in the ephemeral
# sandbox, never in the repo (the repo only ever holds the encrypted .enc).
ADC_KEY="/tmp/gcp-adc-credentials.json"
if ! (umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out "$ADC_KEY" 2>/dev/null); then
  echo "WARNING: Failed to decrypt credentials — check GCP_CREDENTIALS_KEY or .enc file integrity."
  rm -f "$ADC_KEY"
  exit 0
fi

if ! gcloud auth activate-service-account --key-file="$ADC_KEY" 2>/dev/null; then
  echo "WARNING: gcloud auth failed — credentials may be revoked."
  rm -f "$ADC_KEY"
  exit 0
fi
# Select the configured project and confirm it took. A failure here would leave
# an earlier cached project active, so later commands would hit the wrong one:
# treat it like an authentication failure and log the account out again.
PROJECT_ID=$(jq -r '.project_id // empty' "$CONFIG" 2>/dev/null)
if [ -z "$PROJECT_ID" ] || ! gcloud config set project "$PROJECT_ID" 2>/dev/null \
   || [ "$(gcloud config get-value project 2>/dev/null)" != "$PROJECT_ID" ]; then
  echo "WARNING: could not select GCP project '$PROJECT_ID' — logging out."
  gcloud auth revoke "$(jq -r .client_email "$ADC_KEY")" 2>/dev/null || true
  rm -f "$ADC_KEY"
  exit 0
fi

# --- Populate Application Default Credentials for Python client libraries ---
export GOOGLE_APPLICATION_CREDENTIALS="$ADC_KEY"

# --- Persist gcloud PATH + ADC env for the rest of the session ---
# SessionStart runs in a short-lived subprocess; without persisting these,
# later commands in the session would not find gcloud or have ADC set.
# $CLAUDE_ENV_FILE is the harness mechanism for exporting env to the session
# (the same approach this skill's AWS hook uses for its credentials).
if [ -n "$CLAUDE_ENV_FILE" ]; then
  GCLOUD_BIN="$(dirname "$(command -v gcloud)")"
  grep -qxF "export PATH=\"$GCLOUD_BIN:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "export PATH=\"$GCLOUD_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
  grep -qxF "export GOOGLE_APPLICATION_CREDENTIALS=\"$ADC_KEY\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "export GOOGLE_APPLICATION_CREDENTIALS=\"$ADC_KEY\"" >> "$CLAUDE_ENV_FILE"
fi

echo "GCP credentials activated for $USER_EMAIL (gcloud CLI + Python ADC)"
```

Then add to `.claude/settings.json` (create the file and directories if needed):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/cloud-auth.sh\"",
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

If `.claude/settings.json` already exists, merge the `SessionStart` hook into the existing `hooks` object. Commit both `.claude/hooks/cloud-auth.sh` and `.claude/settings.json`.

## API Base

All API calls use `curl -H "Authorization: Bearer $TOKEN"` against `https://` endpoints.

## Create Service Account

```bash
# Create the service account. Stop on any HTTP error: a 409 means a
# `claude-agent` account already exists in this project, and granting roles to
# or creating keys for that pre-existing account would hand out an identity this
# setup did not create. Agree a different accountId with the user instead.
SA_ID="${SA_ID:-claude-agent}"
RESP=$(mktemp)
if ! curl -sS --fail -X POST \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "accountId": "'"$SA_ID"'",
    "serviceAccount": {
      "displayName": "Claude Code Agent"
    }
  }' > "$RESP"; then
  rm -f "$RESP"
  echo "ERROR: service account creation failed (409 = it already exists); choose another accountId with the user."
  exit 1
fi
SA_EMAIL=$(jq -r '.email // empty' "$RESP"); rm -f "$RESP"
[ -n "$SA_EMAIL" ] || { echo "ERROR: creation response has no service-account email."; exit 1; }
echo "Created $SA_EMAIL; set SA_EMAIL to this in every later setup snippet."
```

`SA_EMAIL` (normally `claude-agent@$PROJECT_ID.iam.gserviceaccount.com`, or `$SA_ID@...` if the user chose another id) is the identity every later step binds to: grant roles to it, create its key, and record it as `service_account` in `.cloud-config.json`.

## Grant Roles

For each role, read the **full** current policy (version 3), add the binding, and write the same object back. Keeping the fetched `etag`, `version`, and `auditConfigs` matters: `setIamPolicy` replaces the whole policy, a missing `etag` can overwrite a concurrent change, and writing a version-1 policy over a version-3 one drops its conditional bindings.

```bash
ROLE="roles/ROLE_NAME"
# Bind to the account setup actually created (SA_EMAIL from Create Service
# Account), or in a later session the one recorded in config; never a
# hard-coded name, which could be a different, pre-existing account.
SA_EMAIL="${SA_EMAIL:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
[ -n "$SA_EMAIL" ] || { echo "ERROR: SA_EMAIL is not set; run Create Service Account first."; exit 1; }
MEMBER="serviceAccount:$SA_EMAIL"

# Private, unique scratch space (no fixed /tmp names to race on or clobber)
WORK=$(mktemp -d)

# Get the current IAM policy, including etag, version, and auditConfigs
if ! curl -sS --fail -X POST \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT_ID:getIamPolicy" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"options": {"requestedPolicyVersion": 3}}' > "$WORK/policy.json"; then
  rm -rf "$WORK"; echo "ERROR: getIamPolicy failed; role $ROLE not granted."; exit 1
fi

# Add the member to the unconditional binding for ROLE (or create it),
# keeping every other field of the fetched policy untouched
jq --arg r "$ROLE" --arg m "$MEMBER" '
  .version = 3
  | .bindings = (.bindings // [])
  | if any(.bindings[]; .role == $r and .condition == null)
    then .bindings |= map(if .role == $r and .condition == null
                          then .members = ((.members + [$m]) | unique) else . end)
    else .bindings += [{role: $r, members: [$m]}] end
  | {policy: .}' "$WORK/policy.json" > "$WORK/new-policy.json" \
  || { rm -rf "$WORK"; echo "ERROR: could not build the new policy."; exit 1; }

# Write it back; a 409 (etag mismatch) means someone else changed the policy:
# re-run both steps rather than forcing the write. Stop on any failure, so setup
# never goes on to create a key for an account missing an approved role.
if curl -sS --fail -X POST \
  "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT_ID:setIamPolicy" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$WORK/new-policy.json"; then
  rm -rf "$WORK"
else
  rm -rf "$WORK"
  echo "ERROR: setIamPolicy failed (409 = concurrent change: re-run from getIamPolicy); role $ROLE not granted."
  exit 1
fi
```

**Important:** Merge new bindings with existing ones. Do not overwrite the entire policy.

## Create Key

This command works for both first-time setup and adding new team members. Each call creates a new, independent key for the same service account.

```bash
# Resolve the project and service account from config (provider-aware: in
# multi-provider repos these live inside the matching providers[] entry).
# add-team-member/rotation reuse this snippet with no first-time vars in scope,
# so PROJECT_ID must be resolved here too, not assumed.
PROJECT_ID="${PROJECT_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)}"
SA_EMAIL="${SA_EMAIL:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
# No fallback to a guessed name: during first-time setup this is the SA_EMAIL
# Create Service Account printed, and a guess could name another account.
[ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: set PROJECT_ID and SA_EMAIL (the account Create Service Account created)."; exit 1; }

# Fail on HTTP errors and validate the response before writing a key file, so
# an error body is never decoded into credentials.json and encrypted.
RESP=$(umask 077 && mktemp)
if ! curl -sS --fail -X POST \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keyAlgorithm": "KEY_ALG_RSA_2048"}' > "$RESP"; then
  echo "ERROR: key creation failed."; rm -f "$RESP"; exit 1
fi
# The key now exists at Google. Keep its resource name until the local file is
# validated; on any local failure, delete the key so it is not left orphaned.
KEY_NAME=$(jq -r '.name // empty' "$RESP")
KEY_DATA=$(jq -r '.privateKeyData // empty' "$RESP"); rm -f "$RESP"
discard_new_key() {   # deletes the key by its resource name; see scripts/discard-credential.sh
  CRED_ID="$KEY_NAME" TOKEN="${TOKEN:-}" GRAPH_TOKEN="${GRAPH_TOKEN:-}" PROJECT_ID="${PROJECT_ID:-}" SA_EMAIL="${SA_EMAIL:-}" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh gcp
}
[ -n "$KEY_DATA" ] || { echo "ERROR: response has no privateKeyData."; discard_new_key; exit 1; }
(umask 077 && printf '%s' "$KEY_DATA" | base64 -d > credentials.json) \
  || { echo "ERROR: could not decode the key."; discard_new_key; exit 1; }
jq -e '.type == "service_account" and .private_key' credentials.json >/dev/null \
  || { echo "ERROR: decoded key is not a service-account key."; discard_new_key; exit 1; }
KEY_ID=$(jq -r .private_key_id credentials.json)
```

### Record the key's owner

A service-account key carries no member label, and its ID is otherwise stored only inside that member's encrypted file. Record which member owns which key in `.cloud-config.json` (the ID is not secret), so the key can be found and deleted when the member leaves even if their passphrase is gone. Run this once `.cloud-config.json` exists (during first-time setup, right after writing it) and commit the config with the `.enc` file:

```bash
# Provider-aware: in multi-provider configs the map lives in the gcp entry.
# Snippets may run in fresh shells: take KEY_ID from this shell, else from
# credentials.json, else from the member's encrypted file (KEY from SKILL.md).
USER_EMAIL=$(git config user.email)
if [ -z "$KEY_ID" ] && [ -f credentials.json ]; then
  KEY_ID=$(jq -r '.private_key_id // empty' credentials.json)
fi
if [ -z "$KEY_ID" ]; then
  for f in ".cloud-credentials.gcp.${USER_EMAIL}.enc" ".cloud-credentials.${USER_EMAIL}.enc"; do
    [ -f "$f" ] || continue
    KEY_ID=$(printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$f" 2>/dev/null \
      | jq -r '.private_key_id // empty')
    [ -n "$KEY_ID" ] && break
  done
fi
[ -n "$KEY_ID" ] || { echo "ERROR: could not determine this member's key ID; nothing recorded."; exit 1; }
jq --arg e "$USER_EMAIL" --arg k "$KEY_ID" '
  if .providers then .providers |= map(if .provider == "gcp" then .key_ids[$e] = $k else . end)
  else .key_ids[$e] = $k end' .cloud-config.json > .cloud-config.json.tmp \
  && mv .cloud-config.json.tmp .cloud-config.json
```

## Key Management

List existing keys (useful if approaching the 10-key limit). Resolve the
configured service account first (do not hard-code `claude-agent`):

```bash
PROJECT_ID="${PROJECT_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)}"
SA_EMAIL="${SA_EMAIL:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
# No fallback to a guessed name: during first-time setup this is the SA_EMAIL
# Create Service Account printed, and a guess could name another account.
[ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: set PROJECT_ID and SA_EMAIL (the account Create Service Account created)."; exit 1; }
curl -X GET \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys" \
  -H "Authorization: Bearer $TOKEN"
```

Delete a member's key (if a team member leaves or a key is compromised). Look the key up in the `key_ids` map ("Record the key's owner"). Setups made before that map existed have no entry: list the keys as above and match the member by the key's `validAfterTime` against the commit that added their `.enc` file (`git log --diff-filter=A --format=%cI -- <file>`); if no key matches unambiguously, ask the user rather than guess. A member's `revoke_pending` list names old keys a rotation could not delete yet; the snippet below deletes those too, since they are still live.

```bash
MEMBER_EMAIL="departed-user@example.com"
# Resolve the identity here too: this block may run in a fresh shell
PROJECT_ID="${PROJECT_ID:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)}"
SA_EMAIL="${SA_EMAIL:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
[ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: could not resolve the GCP project and service account from .cloud-config.json."; exit 1; }
# The member's current key plus any old keys still awaiting revocation
IDS=$(jq -r --arg e "$MEMBER_EMAIL" '(if .providers then (.providers[] | select(.provider=="gcp")) else . end)
  | ([.key_ids[$e] // empty] + ((.revoke_pending[$e] // []) | if type == "string" then [.] else . end)) | unique | .[]' .cloud-config.json)
[ -n "$IDS" ] || { echo "ERROR: no recorded key for $MEMBER_EMAIL; find it from the key list first."; exit 1; }
# Each ID leaves the config only once Google confirms it is gone (deleted now,
# or 404 because it already was); the .enc file goes only when every key is.
FAILED=""
for ID in $IDS; do
  HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys/$ID" \
    -H "Authorization: Bearer $TOKEN")
  # 404: the key no longer exists (deleted earlier), so its record can go too
  if [ "$HTTP" = 200 ] || [ "$HTTP" = 404 ]; then
    jq --arg e "$MEMBER_EMAIL" --arg id "$ID" '
      def clr: (if .key_ids[$e] == $id then del(.key_ids[$e]) else . end)
        | (if .revoke_pending[$e] then .revoke_pending[$e] = ((.revoke_pending[$e] | if type == "string" then [.] else . end) - [$id]) else . end)
        | (if .revoke_pending[$e] == [] then del(.revoke_pending[$e]) else . end);
      if .providers then .providers |= map(if .provider == "gcp" then clr else . end)
      else clr end' .cloud-config.json > .cloud-config.json.tmp \
      && mv .cloud-config.json.tmp .cloud-config.json \
      || { echo "ERROR: key $ID is deleted but .cloud-config.json could not be updated."; FAILED="$FAILED $ID"; }
  else
    FAILED="$FAILED $ID"
  fi
done
if [ -n "$FAILED" ]; then
  echo "ERROR: still active:$FAILED. The member's .enc file and their remaining IDs stay; retry with a fresh token."; exit 1
fi
git rm -q --ignore-unmatch ".cloud-credentials.${MEMBER_EMAIL}.enc" ".cloud-credentials.gcp.${MEMBER_EMAIL}.enc"
```

Commit the removed `.enc` file and the updated `.cloud-config.json` together.

## Activate (Subsequent Sessions)

Decrypt to a session-stable, private path and keep it for the session so Python
Google client libraries (which use Application Default Credentials, not the
gcloud CLI auth store) can authenticate too:

```bash
# Decrypt directly to the session ADC path so this snippet is self-contained
# (don't assume SessionStart already left a file behind). KEY/ENC_FILE come
# from the Authenticate workflow.
ADC_KEY="/tmp/gcp-adc-credentials.json"   # decrypted here, never committed
# A preset CLOUDSDK_AUTH_ACCESS_TOKEN outranks the activated account in
# gcloud's credential order: clear it here and for the rest of the session
unset CLOUDSDK_AUTH_ACCESS_TOKEN
if [ -n "$CLAUDE_ENV_FILE" ]; then
  grep -qxF "unset CLOUDSDK_AUTH_ACCESS_TOKEN" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "unset CLOUDSDK_AUTH_ACCESS_TOKEN" >> "$CLAUDE_ENV_FILE"
fi
(umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out "$ADC_KEY")
gcloud auth activate-service-account --key-file="$ADC_KEY"
# Provider-aware project: in multi-provider repos project_id is in providers[].
gcloud config set project "$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end)' .cloud-config.json)"
export GOOGLE_APPLICATION_CREDENTIALS="$ADC_KEY"
# If running outside the same shell, persist via $CLAUDE_ENV_FILE (see hook).
```

Do **not** delete the decrypted key while the session is using it for ADC; it
lives only in the ephemeral sandbox and is never written to the repo.

## Verify (Smoke Test)

After activating credentials, run this lightweight check to confirm they work:

```bash
# Minting a token exchanges the service-account key with Google, so it fails if
# the key was deleted or disabled, and it needs no project-level API or role.
gcloud auth print-access-token >/dev/null && gcloud config get-value account
```

Then exercise one capability the granted roles actually allow (for example `gcloud storage ls gs://<bucket>/` for a storage role, or `bq query --use_legacy_sql=false 'SELECT 1'` for BigQuery). Avoid `gcloud projects describe` as the check: it needs the Cloud Resource Manager API enabled on the project and fails for valid keys where it is off.

If the token step fails, the credentials may be expired or revoked. Re-run the **Authenticate** flow or ask the user to check the service account.

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
