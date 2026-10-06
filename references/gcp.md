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

# Undo an earlier activation in this container (gcloud's stored account, the
# ADC key file, the persisted export) whenever this run exits without renewing
# it: a removed passphrase or a broken file must disable repository auth, not
# leave the previous session's identity in place.
ADC_KEY="/tmp/gcp-adc-credentials.json"
# Note the earlier account now: a replacement key moved over the file before a
# failed login would otherwise hide which cached account still needs revoking
PRIOR_SA=$(jq -r '.client_email // empty' "$ADC_KEY" 2>/dev/null || true)
clear_prior_gcp() {
  local G A
  for G in gcloud /home/user/google-cloud-sdk/bin/gcloud; do
    command -v "$G" >/dev/null 2>&1 || continue
    for A in "$PRIOR_SA" "$(jq -r '.client_email // empty' "$ADC_KEY" 2>/dev/null)"; do
      [ -z "$A" ] || "$G" auth revoke "$A" >/dev/null 2>&1 || true
    done
    break
  done
  rm -f "$ADC_KEY" "$ADC_KEY.new"
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
    sed -i '/GOOGLE_APPLICATION_CREDENTIALS/d' "$CLAUDE_ENV_FILE"
    echo "unset GOOGLE_APPLICATION_CREDENTIALS" >> "$CLAUDE_ENV_FILE"
  fi
}
trap '[ "${GCP_ACTIVATED:-}" = 1 ] || clear_prior_gcp' EXIT

# Claude Code on the Web can preset CLOUDSDK_AUTH_ACCESS_TOKEN, which outranks
# the activated service account in gcloud's credential order. Clear it for this
# script and the whole session before any early exit, including a missing or
# unreadable config, so gcloud fails instead of running as the ambient principal.
# (Set after the cleanup trap: a failed write here must still clear an
# earlier activation)
unset CLOUDSDK_AUTH_ACCESS_TOKEN
if [ -n "$CLAUDE_ENV_FILE" ]; then
  grep -qxF "unset CLOUDSDK_AUTH_ACCESS_TOKEN" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "unset CLOUDSDK_AUTH_ACCESS_TOKEN" >> "$CLAUDE_ENV_FILE"
fi

# --- Auto-authenticate if credentials exist ---
CONFIG=".cloud-config.json"
if [ ! -f "$CONFIG" ]; then exit 0; fi

PROVIDER=$(jq -r .provider "$CONFIG" 2>/dev/null) || exit 0
if [ "$PROVIDER" != "gcp" ]; then exit 0; fi

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
# Decrypt to a separate file and check it before it replaces the key file
NEW_KEY="$ADC_KEY.new"
if ! (umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out "$NEW_KEY" 2>/dev/null); then
  echo "WARNING: Failed to decrypt credentials — check GCP_CREDENTIALS_KEY or .enc file integrity."
  rm -f "$NEW_KEY"
  exit 0
fi

# Use the key only if it is for the configured service account: a stale or
# copied file could hold a valid key for another account in the same project
SA_CFG=$(jq -r '.service_account // empty' "$CONFIG" 2>/dev/null)
if [ -z "$SA_CFG" ] || [ "$(jq -r '.client_email // empty' "$NEW_KEY" 2>/dev/null)" != "$SA_CFG" ]; then
  echo "WARNING: $ENC_FILE is not a key for ${SA_CFG:-the configured service account}; not activating it."
  rm -f "$NEW_KEY"
  exit 0
fi
# ...and only this member's own key: key_ids maps each member to theirs (an
# open rotation, which commits the new key before key_ids names it, excepted)
WHY=$(jq -r --arg e "$USER_EMAIL" --arg k "$(jq -r '.private_key_id // empty' "$NEW_KEY")" \
  '(if .providers then (.providers[] | select(.provider == "gcp")) else . end) | (.key_ids // {}) as $m
  | if any($m | to_entries[]; .key != $e and (.value | split("/") | last) == $k) then "its key is recorded for another member"
    elif ($m[$e] // "") != "" and ($m[$e] | split("/") | last) != $k and ((.rotating // {})[$e] // "") == "" then "its key differs from the key_ids entry for this member"
    else "ok" end' "$CONFIG" 2>/dev/null)
if [ "$WHY" != ok ]; then
  echo "WARNING: $ENC_FILE not activated: ${WHY:-its key could not be checked}."
  rm -f "$NEW_KEY"
  exit 0
fi
mv -f "$NEW_KEY" "$ADC_KEY"

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
  # Drop an unset an earlier failed run left, so the export below takes effect
  sed -i '/^unset GOOGLE_APPLICATION_CREDENTIALS$/d' "$CLAUDE_ENV_FILE" 2>/dev/null || true
  grep -qxF "export GOOGLE_APPLICATION_CREDENTIALS=\"$ADC_KEY\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "export GOOGLE_APPLICATION_CREDENTIALS=\"$ADC_KEY\"" >> "$CLAUDE_ENV_FILE"
fi

# A different account activated earlier (the configured service account
# changed) stays cached in gcloud until revoked: revoke it now that the new
# one is in place
NEW_SA=$(jq -r '.client_email // empty' "$ADC_KEY" 2>/dev/null || true)
if [ -n "$PRIOR_SA" ] && [ "$PRIOR_SA" != "$NEW_SA" ]; then
  gcloud auth revoke "$PRIOR_SA" >/dev/null 2>&1 || true
fi
GCP_ACTIVATED=1
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
# Create the service account. Stop on any HTTP error: a 409 means an account
# with this ID already exists in this project, and granting roles to or
# creating keys for that pre-existing account would hand out an identity this
# setup did not create. The default ID has a random per-run suffix, so a
# concurrent setup never targets the same account; an account found under it
# after an ambiguous failure is this run's. Keep SA_ID (or the user's own
# choice) for every later snippet.
if [ -z "${SA_ID:-}" ]; then
  SA_ID="claude-agent-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; SA_ID_GENERATED=1
fi
echo "Service account ID for this setup: $SA_ID"
SA_URL="https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_ID@$PROJECT_ID.iam.gserviceaccount.com"
sa_exists() {   # 0 = exists, 1 = absent (HTTP 404), 2 = could not tell
  case "$(curl -sS -o /dev/null -w '%{http_code}' "$SA_URL" -H "Authorization: Bearer $TOKEN")" in
    200) return 0 ;; 404) return 1 ;; *) return 2 ;;
  esac
}
# It must not exist yet: anything found afterwards is then ours to remove
# (if/else so the expected 404 does not stop a `set -e` shell)
if sa_exists; then S=0; else S=$?; fi
case $S in
  0) echo "ERROR: $SA_ID already exists; choose another accountId with the user."; exit 1 ;;
  2) echo "ERROR: could not check whether $SA_ID exists; nothing created."; exit 1 ;;
esac
# The record must never be committed: make sure .gitignore covers it (setups
# made before it existed lack the rule)
grep -qxF '/.cloud-setup-pending.json' .gitignore 2>/dev/null || echo '/.cloud-setup-pending.json' >> .gitignore
# Create nothing unless git really ignores the plaintext and the record: a
# failed write (read-only file, full disk) would leave a live key committable
git check-ignore -q credentials.json && git check-ignore -q .cloud-setup-pending.json \
  || { echo "ERROR: .gitignore does not cover /credentials.json and /.cloud-setup-pending.json (First-Time Setup step 1a); nothing created."; exit 1; }
# The git email names the credential file and the member's key_ids entry: an
# empty one would leave a credential no later session can find
[ -n "$(git config user.email)" ] \
  || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry. Nothing created."; exit 1; }
# Record the account before creating it (not secret), so "Rollback a Failed
# Setup" can find it from any shell if this run stops part-way
jq -n --arg p "$PROJECT_ID" --arg s "$SA_ID@$PROJECT_ID.iam.gserviceaccount.com" \
  '{provider: "gcp", project_id: $p, service_account: $s}' > .cloud-setup-pending.json \
  || { echo "ERROR: could not write .cloud-setup-pending.json; nothing created."; exit 1; }
RESP=$(umask 077 && mktemp)
# (if/else so the status is captured even under `set -e`)
if HTTP=$(curl -sS -o "$RESP" -w '%{http_code}' -X POST \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "accountId": "'"$SA_ID"'",
    "serviceAccount": {
      "displayName": "Claude Code Agent"
    }
  }'); then RC=0; else RC=$?; fi
case "$RC:$HTTP" in
  0:2??) ;;   # created
  0:4??)      # Google rejected the request (409 = it already exists): nothing was created
    rm -f "$RESP" .cloud-setup-pending.json
    echo "ERROR: service account creation was rejected (HTTP $HTTP); nothing was created."
    exit 1 ;;
  *)          # a 5xx or a transport/local failure: the account may exist anyway.
              # It did not exist before, so if it exists now, this call made it.
    rm -f "$RESP"
    # A new service account can take a minute or more to become visible: call
    # it absent only after it stays absent across retries
    for DELAY in 0 20 40 60; do
      sleep "$DELAY"
      if sa_exists; then S=0; else S=$?; fi
      [ "$S" = 1 ] || break
    done
    if [ "$S" = 0 ] && [ "${SA_ID_GENERATED:-}" != 1 ]; then
      # A chosen ID could also be another run's: keep the account for the user
      # to check. Mark the record, so the rollback (and the next session's
      # recovery) leaves the account alone until a person confirms it
      if jq '. + {ambiguous: true}' .cloud-setup-pending.json > .cloud-setup-pending.json.tmp \
        && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json; then
        echo "WARNING: $SA_ID exists now, created by this run or by another setup using the same ID."
        echo "Check with the user before running Rollback a Failed Setup with CONFIRM_SA=1 (or delete the record if it is not this run's)."
      else
        # Unmarked, the record would let a rollback delete an account that may
        # be another setup's; it names nothing else yet, so drop it
        rm -f .cloud-setup-pending.json.tmp .cloud-setup-pending.json
        echo "WARNING: $SA_ID exists now and the record could not be marked as unconfirmed, so it was removed."
        echo "Check with the user whether $SA_ID is this run's; only then delete it by hand."
        [ ! -e .cloud-setup-pending.json ] || echo "ERROR: .cloud-setup-pending.json could not be removed either; delete it by hand before any rollback."
      fi
    elif [ "$S" = 0 ]; then
      curl -sS --fail -X DELETE "$SA_URL" -H "Authorization: Bearer $TOKEN" >/dev/null \
        && { echo "Removed $SA_ID, which the failed call had created."; rm -f .cloud-setup-pending.json; } \
        || echo "WARNING: could not delete $SA_ID; run Rollback a Failed Setup before retrying."
    elif [ "$S" = 1 ]; then
      rm -f .cloud-setup-pending.json   # nothing was created
    fi
    echo "ERROR: service account creation failed (curl exit $RC, HTTP ${HTTP:-none})."
    exit 1 ;;
esac
SA_EMAIL=$(jq -r '.email // empty' "$RESP" 2>/dev/null); rm -f "$RESP"
if [ -z "$SA_EMAIL" ]; then
  # Created, but the response is unusable: remove the account so a retry is not
  # blocked by the pre-existing-account check
  curl -sS --fail -X DELETE "$SA_URL" -H "Authorization: Bearer $TOKEN" >/dev/null \
    && { echo "ERROR: creation response has no service-account email; removed $SA_ID."; rm -f .cloud-setup-pending.json; } \
    || echo "ERROR: creation response has no service-account email, and $SA_ID could not be deleted; run Rollback a Failed Setup."
  exit 1
fi
echo "Created $SA_EMAIL; set SA_EMAIL to this in every later setup snippet."
```

### Rollback a Failed Setup

Undo a first-time setup or provider addition that did not finish. Run it from any shell: it reads the account from `.cloud-setup-pending.json` (or `PROJECT_ID`/`SA_EMAIL`). It first removes the account from every binding in the project policy, since bindings of a deleted account linger for up to 60 days, then deletes the account, which deletes its keys with it. A 404 means the account is already gone.

```bash
PENDING=.cloud-setup-pending.json
# With a record, its identity wins: a value left in the shell by another
# operation must match it or be unset (shell values are used only without one)
HAVE_REC=$(jq -r 'select(.provider == "gcp") | "yes"' "$PENDING" 2>/dev/null)
pick() {   # $1 = variable, $2 = the record's value
  [ -n "$HAVE_REC" ] || return 0
  [ -z "${!1:-}" ] || [ "${!1}" = "$2" ] \
    || { echo "ERROR: $1 is ${!1}, but $PENDING names ${2:-none}; nothing changed. Unset $1."; exit 1; }
  printf -v "$1" '%s' "$2"
}
pick PROJECT_ID "$(jq -r 'select(.provider == "gcp") | .project_id // empty' "$PENDING" 2>/dev/null)"
pick SA_EMAIL "$(jq -r 'select(.provider == "gcp") | .service_account // empty' "$PENDING" 2>/dev/null)"
[ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: set PROJECT_ID and SA_EMAIL (no GCP entry in $PENDING)."; exit 1; }
# An unconfirmed record (a create call failed, then a chosen ID turned up)
# may name another setup's account: touch it only once a person confirms
if [ "$(jq -r 'select(.provider == "gcp") | .ambiguous // empty' "$PENDING" 2>/dev/null)" = true ] && [ "${CONFIRM_SA:-}" != 1 ]; then
  echo "ERROR: $PENDING marks $SA_EMAIL as possibly another setup's; nothing changed."
  echo "Confirm with the user it is this run's account, then re-run with CONFIRM_SA=1 (or delete $PENDING if it is not)."
  exit 1
fi
RB_OK=1; WORK=$(mktemp -d) && [ -d "$WORK" ] || { echo "ERROR: could not create a private temp directory; nothing changed."; exit 1; }
CRM="https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT_ID"
if curl -sS --fail -X POST "$CRM:getIamPolicy" -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" -d '{"options": {"requestedPolicyVersion": 3}}' > "$WORK/policy.json"; then
  M="serviceAccount:$SA_EMAIL"
  if jq -e --arg m "$M" 'any(.bindings[]?; (.members // []) | index($m))' "$WORK/policy.json" >/dev/null; then
    # Same policy-preserving write as Grant Roles (etag, version, auditConfigs kept)
    jq --arg m "$M" '.version = 3
      | .bindings = [(.bindings // [])[] | .members -= [$m] | select(.members | length > 0)]
      | {policy: .}' "$WORK/policy.json" > "$WORK/new-policy.json" \
      && curl -sS --fail -X POST "$CRM:setIamPolicy" -H "Authorization: Bearer $TOKEN" \
           -H "Content-Type: application/json" -d @"$WORK/new-policy.json" >/dev/null \
      || { RB_OK=0; echo "WARNING: could not remove $SA_EMAIL from the project policy (409 = concurrent change: re-run)."; }
  fi
else
  RB_OK=0; echo "WARNING: could not read the project policy; $SA_EMAIL's role bindings may remain."
fi
rm -rf "$WORK"
# Delete the account only once its bindings are gone: afterwards Google
# rewrites them as deleted-principal members this block can no longer match
if [ "$RB_OK" = 1 ]; then
  # A just-created account can read as missing (404) for a minute or more:
  # count 404 as deleted only once it persists across retries
  for DELAY in 0 20 40 60; do
    sleep "$DELAY"
    HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL" -H "Authorization: Bearer $TOKEN")
    [ "$HTTP" = 404 ] || break
  done
  case "$HTTP" in
    200|404) echo "Service account $SA_EMAIL is deleted." ;;
    *) RB_OK=0; echo "WARNING: could not delete $SA_EMAIL (HTTP $HTTP)." ;;
  esac
else
  echo "The service account is kept until its bindings are removed."
fi
if [ "$RB_OK" = 1 ]; then
  # The account and all its keys are gone: drop "unrevoked" entries that name
  # its keys (a failed discard may have recorded them), or every later phase
  # check would report credentials that no longer exist
  if [ -f .cloud-config.json ]; then
    jq --arg sa "$SA_EMAIL" '
      .unrevoked = [(.unrevoked // [])[] | select(.provider != "gcp"
          or ((.id | contains("/serviceAccounts/\($sa)/keys/")) | not)
             and (.id != "unknown key of \($sa)"))]
      | if .unrevoked == [] then del(.unrevoked) else . end' .cloud-config.json > .cloud-config.json.tmp \
      && mv .cloud-config.json.tmp .cloud-config.json && echo "Commit .cloud-config.json if it changed." \
      || { rm -f .cloud-config.json.tmp; echo "ERROR: the identity is gone, but .cloud-config.json could not be updated; $PENDING is kept. Fix the file and re-run this block."; exit 1; }
  fi
  rm -f credentials.json "$PENDING"; echo "Rollback complete."
else
  echo "Rollback incomplete; $PENDING is kept. Re-run this block."; exit 1
fi
```

`SA_EMAIL` (`$SA_ID@$PROJECT_ID.iam.gserviceaccount.com`: by default `claude-agent-<random suffix>`, or the ID the user chose) is the identity every later step binds to: grant roles to it, create its key, and record it as `service_account` in `.cloud-config.json`.

## Grant Roles

For each role, read the **full** current policy (version 3), add the binding, and write the same object back. Keeping the fetched `etag`, `version`, and `auditConfigs` matters: `setIamPolicy` replaces the whole policy, a missing `etag` can overwrite a concurrent change, and writing a version-1 policy over a version-3 one drops its conditional bindings.

```bash
ROLE="roles/ROLE_NAME"
# Bind to the account setup actually created (SA_EMAIL from Create Service
# Account), or in a later session the one recorded in config; never a
# hard-coded name, which could be a different, pre-existing account.
# The setup record names it during first-time setup, the config afterwards; an
# SA_EMAIL left in the shell by another operation that disagrees is refused
WANT_SA=$(jq -r 'select(.provider=="gcp") | .service_account // empty' .cloud-setup-pending.json 2>/dev/null)
WANT_SA="${WANT_SA:-$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)}"
if [ -n "$WANT_SA" ]; then
  [ -z "${SA_EMAIL:-}" ] || [ "$SA_EMAIL" = "$WANT_SA" ] \
    || { echo "ERROR: SA_EMAIL is $SA_EMAIL, but this repo's service account is $WANT_SA; no role granted. Unset SA_EMAIL."; exit 1; }
  SA_EMAIL="$WANT_SA"
fi
[ -n "${SA_EMAIL:-}" ] || { echo "ERROR: SA_EMAIL is not set; run Create Service Account first."; exit 1; }
# The project whose policy changes: the configured one (or during setup the
# one in its record); a stale PROJECT_ID that disagrees with it is refused
CFG_PROJECT=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)
CFG_PROJECT="${CFG_PROJECT:-$(jq -r 'select(.provider=="gcp") | .project_id // empty' .cloud-setup-pending.json 2>/dev/null)}"
if [ -n "$CFG_PROJECT" ] && [ -n "${PROJECT_ID:-}" ] && [ "$PROJECT_ID" != "$CFG_PROJECT" ]; then
  echo "ERROR: PROJECT_ID=$PROJECT_ID but this repo is configured for $CFG_PROJECT; no role granted."; exit 1
fi
PROJECT_ID="${CFG_PROJECT:-${PROJECT_ID:-}}"
[ -n "$PROJECT_ID" ] || { echo "ERROR: no GCP project in .cloud-config.json or the setup record; set PROJECT_ID."; exit 1; }
MEMBER="serviceAccount:$SA_EMAIL"

# Private, unique scratch space (no fixed /tmp names to race on or clobber)
WORK=$(mktemp -d) && [ -d "$WORK" ] || { echo "ERROR: could not create a private temp directory; no role granted."; exit 1; }

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
CFG_PROJECT=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)
CFG_SA=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)
# Once GCP is configured, the config decides: a PROJECT_ID or SA_EMAIL left in
# the shell from another setup would point at another account
if [ -n "$CFG_PROJECT$CFG_SA" ]; then
  [ -z "${PROJECT_ID:-}" ] || [ "$PROJECT_ID" = "$CFG_PROJECT" ] \
    || { echo "ERROR: PROJECT_ID=$PROJECT_ID but this repo is configured for $CFG_PROJECT; nothing done."; exit 1; }
  [ -z "${SA_EMAIL:-}" ] || [ "$SA_EMAIL" = "$CFG_SA" ] \
    || { echo "ERROR: SA_EMAIL=$SA_EMAIL but this repo is configured for $CFG_SA; nothing done."; exit 1; }
  PROJECT_ID="$CFG_PROJECT"; SA_EMAIL="$CFG_SA"
fi
# No fallback to a guessed name: during first-time setup this is the SA_EMAIL
# Create Service Account printed, and a guess could name another account.
[ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: set PROJECT_ID and SA_EMAIL (the account Create Service Account created)."; exit 1; }

# List the account's keys first, so a key an ambiguous failure may have left
# behind can be found afterwards
KEYS_URL="https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys"
list_keys() { local R; R=$(curl -sS --fail -G "$KEYS_URL" --data-urlencode "keyTypes=USER_MANAGED" \
  -H "Authorization: Bearer $TOKEN") && printf '%s' "$R" | jq -r '.keys[]?.name'; }
KEYS_BEFORE=$(list_keys) || { echo "ERROR: could not list the account's keys; nothing created."; exit 1; }

# Keys new since KEYS_BEFORE after an ambiguous outcome. Their private key
# existed only in a response that never arrived, so nobody holds them and they
# grant no access, but each takes one of the account's 10 slots. GCP keys carry
# no owner label, so one may instead be a teammate's concurrent onboarding:
# record the candidates for a person to check instead of deleting them.
record_new_keys() {
  local AFTER NEW NAME
  if ! AFTER=$(list_keys); then
    echo "WARNING: could not list keys; compare them with the list before this call by hand."
    # Nothing else would show that a key may exist: record a placeholder, so
    # the next session reports it instead of starting over
    if [ -f .cloud-config.json ]; then
      jq --arg sa "$SA_EMAIL" --arg m "$(git config user.email)" --arg t "$(date -u +%FT%TZ)" \
        '.unrevoked = ((.unrevoked // []) + [{provider: "gcp", id: "unknown key of \($sa)", member: $m, ambiguous: true,
           note: "a key create call failed and the keys could not be listed afterwards: compare the account keys with key_ids", at: $t}])' \
        .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
        && echo "Recorded under \"unrevoked\" in .cloud-config.json; commit it." \
        || { rm -f .cloud-config.json.tmp; echo "ERROR: could not record it either: $SA_EMAIL may have a key no record names."; }
    fi
    return 1
  fi
  # (sed drops the empty line an empty list leaves, which grep -f would match everywhere)
  NEW=$(printf '%s\n' "$AFTER" | grep -vxF -f <(printf '%s\n' "$KEYS_BEFORE" | sed '/^$/d') || true)
  [ -n "$NEW" ] || return 0
  if [ ! -f .cloud-config.json ]; then
    # First-time setup: no teammate can be onboarding yet, and the setup
    # rollback deletes the service account with every key on it
    echo "Run Rollback a Failed Setup (it deletes $SA_EMAIL) before retrying."; return 0
  fi
  local UNREC=""
  for NAME in $NEW; do
    jq --arg id "$NAME" --arg m "$(git config user.email)" --arg t "$(date -u +%FT%TZ)" \
      '.unrevoked = ((.unrevoked // []) + [{provider: "gcp", id: $id, member: $m, ambiguous: true,
         note: "may be an unused key from a failed create call, or a teammate'"'"'s key created at the same time", at: $t}])' \
      .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
      || { rm -f .cloud-config.json.tmp; UNREC="$UNREC $NAME"; }
  done
  if [ -n "$UNREC" ]; then
    # Nothing durable names these keys: stop with the IDs on screen
    echo "ERROR: could not record these keys in .cloud-config.json (fix the file, then add them under \"unrevoked\" by hand):"
    printf '  %s\n' $UNREC
    return 1
  fi
  echo "Keys created since the request began (recorded as ambiguous under \"unrevoked\"; commit .cloud-config.json):"
  printf '  %s\n' $NEW
  echo "Delete each one that is not a teammate's (not in any key_ids entry once their onboarding is committed)."
}

# Check the HTTP status and validate the response before writing a key file,
# so an error body is never decoded into credentials.json and encrypted.
RESP=$(umask 077 && mktemp)
# From the request until credentials.json is written, the key exists only in
# RESP (outside the repo, where the interrupted-run check does not look): if
# this shell is stopped, revoke the key named in a complete response, else
# record the candidates. Afterwards a leftover credentials.json drives recovery.
on_signal() {
  local N; N=$(jq -r '.name // empty' "$RESP" 2>/dev/null)
  if [ -n "$N" ]; then
    CRED_ID="$N" CRED_ID_FROM_RESPONSE=1 TOKEN="${TOKEN:-}" bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh gcp
  else
    record_new_keys
  fi
  rm -f "$RESP"; exit 1
}
trap on_signal INT TERM HUP
# (if/else so the status is captured even under `set -e`)
if HTTP=$(curl -sS -o "$RESP" -w '%{http_code}' -X POST "$KEYS_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keyAlgorithm": "KEY_ALG_RSA_2048"}'); then RC=0; else RC=$?; fi
case "$RC:$HTTP" in
  0:2??) ;;   # created
  0:4??)      # Google rejected the request: no key was created
    trap - INT TERM HUP
    rm -f "$RESP"; echo "ERROR: key creation was rejected (HTTP $HTTP); no key was created."; exit 1 ;;
  *)          # a 5xx or a transport/local failure: a key may exist anyway
    trap - INT TERM HUP
    rm -f "$RESP"
    echo "ERROR: key creation outcome unknown (curl exit $RC, HTTP ${HTTP:-none})."
    record_new_keys
    exit 1 ;;
esac
# The key now exists at Google. Keep its resource name until the local file is
# validated; on any local failure, delete the key so it is not left orphaned.
KEY_NAME=$(jq -r '.name // empty' "$RESP")
KEY_DATA=$(jq -r '.privateKeyData // empty' "$RESP")
discard_new_key() {   # deletes the key by its resource name; see scripts/discard-credential.sh
  CRED_ID="$KEY_NAME" CRED_ID_FROM_RESPONSE=1 TOKEN="${TOKEN:-}" GRAPH_TOKEN="${GRAPH_TOKEN:-}" PROJECT_ID="${PROJECT_ID:-}" SA_EMAIL="${SA_EMAIL:-}" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh gcp
}
[ -n "$KEY_DATA" ] || { echo "ERROR: response has no privateKeyData."; rm -f "$RESP"; discard_new_key; exit 1; }
(umask 077 && printf '%s' "$KEY_DATA" | base64 -d > credentials.json) \
  || { echo "ERROR: could not decode the key."; rm -f "$RESP"; discard_new_key; exit 1; }
# credentials.json now marks the run as unfinished for the next session
trap - INT TERM HUP; rm -f "$RESP"
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
[ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
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
# A different key already recorded for this member (re-onboarding after the
# .enc went missing) may still be live: queue it in revoke_pending, which
# rotation step 9 and member removal work through, instead of dropping it
OLD_KEY=$(jq -r --arg e "$USER_EMAIL" '(if .providers then (.providers[] | select(.provider=="gcp")) else . end) | .key_ids[$e] // empty' .cloud-config.json)
jq --arg e "$USER_EMAIL" --arg k "$KEY_ID" '
  def rec: (if (.key_ids[$e] // "") != "" and .key_ids[$e] != $k
      then .revoke_pending[$e] = (((.revoke_pending[$e] // []) | if type == "string" then [.] else . end) + [.key_ids[$e]] | unique)
      else . end) | .key_ids[$e] = $k;
  if .providers then .providers |= map(if .provider == "gcp" then rec else . end)
  else rec end' .cloud-config.json > .cloud-config.json.tmp \
  && mv .cloud-config.json.tmp .cloud-config.json \
  || { rm -f .cloud-config.json.tmp; echo "ERROR: could not record the key in .cloud-config.json; credentials.json is kept, re-run this step."; exit 1; }
[ -z "$OLD_KEY" ] || [ "$OLD_KEY" = "$KEY_ID" ] \
  || echo "NOTE: $OLD_KEY was recorded for $USER_EMAIL and is now queued in revoke_pending; revoke it (Credential Rotation step 9)."
```

## Key Management

List existing keys (useful if approaching the 10-key limit). Resolve the
configured service account first (do not hard-code `claude-agent`):

```bash
CFG_PROJECT=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)
CFG_SA=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)
# Once GCP is configured, the config decides: a PROJECT_ID or SA_EMAIL left in
# the shell from another setup would point at another account
if [ -n "$CFG_PROJECT$CFG_SA" ]; then
  [ -z "${PROJECT_ID:-}" ] || [ "$PROJECT_ID" = "$CFG_PROJECT" ] \
    || { echo "ERROR: PROJECT_ID=$PROJECT_ID but this repo is configured for $CFG_PROJECT; nothing done."; exit 1; }
  [ -z "${SA_EMAIL:-}" ] || [ "$SA_EMAIL" = "$CFG_SA" ] \
    || { echo "ERROR: SA_EMAIL=$SA_EMAIL but this repo is configured for $CFG_SA; nothing done."; exit 1; }
  PROJECT_ID="$CFG_PROJECT"; SA_EMAIL="$CFG_SA"
fi
# No fallback to a guessed name: during first-time setup this is the SA_EMAIL
# Create Service Account printed, and a guess could name another account.
[ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: set PROJECT_ID and SA_EMAIL (the account Create Service Account created)."; exit 1; }
curl -X GET \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys" \
  -H "Authorization: Bearer $TOKEN"
```

Delete a member's key (if a team member leaves or a key is compromised). Look the key up in the `key_ids` map ("Record the key's owner"). Setups made before that map existed have no entry: list the keys as above and match the member by the key's `validAfterTime` against the commit that added their `.enc` file (`git log --diff-filter=A --format=%cI -- <file>`); if no key matches unambiguously, ask the user rather than guess. Set `KEY_ID` to the key found and, once the user has confirmed it, `CONFIRM_KEY=1`; a `KEY_ID` the config records for another member is refused. A member's `revoke_pending` list names old keys a rotation could not delete yet; the snippet below deletes those too, since they are still live. It skips `unrevoked` entries marked `ambiguous` (keys that appeared while a create call failed): such a key may belong to a teammate who was onboarding at the same time, so compare it with every `key_ids` value, delete it by hand only if no member has it, then drop the entry.

```bash
MEMBER_EMAIL="departed-user@example.com"
# Resolve the identity from the config only (this block may run in a fresh
# shell, or one holding another setup's PROJECT_ID/SA_EMAIL)
PROJECT_ID=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)
SA_EMAIL=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)
[ -n "$PROJECT_ID" ] && [ -n "$SA_EMAIL" ] || { echo "ERROR: could not resolve the GCP project and service account from .cloud-config.json."; exit 1; }
# The member's current key plus any old keys still awaiting revocation
# Every recorded credential of this member: current (key_ids), queued old ones
# (revoke_pending), one an interrupted rotation saved (rotating), and any a
# failed cleanup recorded as unrevoked
IDS=$(jq -r --arg e "$MEMBER_EMAIL" '
  ([.unrevoked[]? | select(.provider == "gcp" and .member == $e and (.ambiguous | not)) | .id | split("/") | last
     | select(test(" ") | not)]) as $u   # placeholders such as "unknown key of ..." name no ID
  | (if .providers then (.providers[] | select(.provider=="gcp")) else . end)
  | ([.key_ids[$e] // empty, .rotating[$e] // empty] + ((.revoke_pending[$e] // []) | if type == "string" then [.] else . end) + $u) | unique | .[]' .cloud-config.json)
# A member added before key_ids existed: the key found from the listing
# A KEY_ID override must not be another member's key, and one the config does
# not record for this member needs CONFIRM_KEY=1 once the person has checked it
# is theirs (key list, creation time): a stale or mistyped ID would otherwise
# delete a teammate's working key
if [ -n "${KEY_ID:-}" ]; then
  KEY_ID="${KEY_ID##*/}"
  OTHERS=$(jq -r --arg e "$MEMBER_EMAIL" '(if .providers then (.providers[] | select(.provider=="gcp")) else . end)
    | [(.key_ids // {}), (.rotating // {}), (.revoke_pending // {})][] | to_entries[] | select(.key != $e)
    | .value | (if type == "array" then .[] else . end) | tostring | split("/") | last' .cloud-config.json)
  ! printf '%s\n' $OTHERS | grep -qxF "$KEY_ID" \
    || { echo "ERROR: KEY_ID $KEY_ID is recorded for another member; nothing deleted."; exit 1; }
  printf '%s\n' $IDS | grep -qxF "$KEY_ID" || [ "${CONFIRM_KEY:-}" = 1 ] \
    || { echo "ERROR: KEY_ID $KEY_ID is not recorded for $MEMBER_EMAIL. Confirm it is theirs, then rerun with CONFIRM_KEY=1; nothing deleted."; exit 1; }
fi
IDS=$(printf '%s\n' $IDS ${KEY_ID:-} | sort -u)
if [ -z "$IDS" ]; then
  # A compromise rotation may already have deleted the member's only
  # credential (revoked_early, no replacement): nothing is live, so clear the
  # member's local state directly
  if [ -n "$(jq -r --arg e "$MEMBER_EMAIL" '(if .providers then (.providers[] | select(.provider=="gcp")) else . end) | .revoked_early[$e] // empty' .cloud-config.json)" ]; then
    jq --arg e "$MEMBER_EMAIL" 'def clr: del(.revoked_early[$e]) | del(.key_ids[$e]) | del(.rotating[$e]) | del(.revoke_pending[$e]);
      if .providers then .providers |= map(if .provider == "gcp" then clr else . end) else clr end' \
      .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json \
      || { rm -f .cloud-config.json.tmp; echo "ERROR: could not update .cloud-config.json; the credential file stays. Fix it and retry."; exit 1; }
    git --literal-pathspecs rm -q --ignore-unmatch ".cloud-credentials.gcp.${MEMBER_EMAIL}.enc" ".cloud-credentials.${MEMBER_EMAIL}.enc"
    echo "$MEMBER_EMAIL has no live credential left; local state cleared."; exit 0
  fi
  echo "ERROR: no recorded key for $MEMBER_EMAIL; find it from the key list first."; exit 1
fi
# Each ID leaves the config only once Google confirms it is gone (deleted now,
# or 404 because it already was); the .enc file goes only when every key is.
FAILED=""
for ID in $IDS; do
  # A key created moments ago can read as missing (404) for a minute or more:
  # count 404 as gone only once it persists across retries
  for DELAY in 0 20 40 60; do
    sleep "$DELAY"
    HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys/$ID" \
      -H "Authorization: Bearer $TOKEN")
    [ "$HTTP" = 404 ] || break
  done
  # 404 throughout: the key no longer exists (deleted earlier), so its record can go too
  if [ "$HTTP" = 200 ] || [ "$HTTP" = 404 ]; then
    jq --arg e "$MEMBER_EMAIL" --arg id "$ID" '
      def clr: (if .key_ids[$e] == $id then del(.key_ids[$e]) else . end)
        | (if .revoke_pending[$e] then .revoke_pending[$e] = ((.revoke_pending[$e] | if type == "string" then [.] else . end) - [$id]) else . end)
        | (if .revoke_pending[$e] == [] then del(.revoke_pending[$e]) else . end)
        | (if .rotating[$e] == $id then del(.rotating[$e]) else . end)
        | del(.revoked_early[$e]);   # its key is gone; a rejoining member starts fresh
      .unrevoked = [(.unrevoked // [])[] | select(.provider != "gcp" or .member != $e or (.id | split("/") | last) != $id)]
      | if .unrevoked == [] then del(.unrevoked) else . end
      | if .providers then .providers |= map(if .provider == "gcp" then clr else . end)
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
git --literal-pathspecs rm -q --ignore-unmatch ".cloud-credentials.${MEMBER_EMAIL}.enc" ".cloud-credentials.gcp.${MEMBER_EMAIL}.enc"
```

Commit the removed `.enc` file and the updated `.cloud-config.json` together.

## Activate (Subsequent Sessions)

Decrypt to a session-stable, private path and keep it for the session so Python
Google client libraries (which use Application Default Credentials, not the
gcloud CLI auth store) can authenticate too:

```bash
# Decrypt to the session ADC path here so this snippet is self-contained
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
# On any failure, leave no repository identity active, as the hook does:
# gcloud keeps an earlier account cached until it is revoked, so note it
# before the new key replaces the file that names it
PRIOR_SA=$(jq -r '.client_email // empty' "$ADC_KEY" 2>/dev/null || true)
gcp_fail() {
  local A
  for A in "$PRIOR_SA" "$(jq -r '.client_email // empty' "$ADC_KEY" 2>/dev/null)"; do
    [ -z "$A" ] || gcloud auth revoke "$A" >/dev/null 2>&1 || true
  done
  rm -f "$ADC_KEY" "$ADC_KEY.new"
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
    sed -i '/GOOGLE_APPLICATION_CREDENTIALS/d' "$CLAUDE_ENV_FILE"
    echo "unset GOOGLE_APPLICATION_CREDENTIALS" >> "$CLAUDE_ENV_FILE"
  fi
  echo "ERROR: $1; any earlier activation was logged out."; exit 1
}
(umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out "$ADC_KEY.new") \
  || gcp_fail "could not decrypt $ENC_FILE"
SA_CFG=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .service_account) else (select(.provider=="gcp") | .service_account) end) // empty' .cloud-config.json 2>/dev/null)
[ -n "$SA_CFG" ] && [ "$(jq -r '.client_email // empty' "$ADC_KEY.new")" = "$SA_CFG" ] \
  || gcp_fail "$ENC_FILE is not a key for ${SA_CFG:-the configured service account}"
# ...and only this member's own key: key_ids maps each member to theirs (an
# open rotation, which commits the new key before key_ids names it, excepted)
WHY=$(jq -r --arg e "$(git config user.email)" --arg k "$(jq -r '.private_key_id // empty' "$ADC_KEY.new")" \
  '(if .providers then (.providers[] | select(.provider == "gcp")) else . end) | (.key_ids // {}) as $m
  | if any($m | to_entries[]; .key != $e and (.value | split("/") | last) == $k) then "its key is recorded for another member"
    elif ($m[$e] // "") != "" and ($m[$e] | split("/") | last) != $k and ((.rotating // {})[$e] // "") == "" then "its key differs from the key_ids entry for this member"
    else "ok" end' .cloud-config.json 2>/dev/null)
[ "$WHY" = ok ] || { rm -f "$ADC_KEY.new"; gcp_fail "$ENC_FILE not activated: ${WHY:-its key could not be checked}"; }
mv -f "$ADC_KEY.new" "$ADC_KEY"
gcloud auth activate-service-account --key-file="$ADC_KEY" \
  || gcp_fail "gcloud could not activate the key (it may be revoked)"
# Provider-aware project: in multi-provider repos project_id is in providers[].
# Stop (and log out) unless exactly the configured project is selected, as the
# hook does: a previously selected project must not stay the default.
PROJECT_ID=$(jq -r '(if .providers then (.providers[] | select(.provider=="gcp") | .project_id) else (select(.provider=="gcp") | .project_id) end) // empty' .cloud-config.json 2>/dev/null)
if [ -z "$PROJECT_ID" ] || ! gcloud config set project "$PROJECT_ID" 2>/dev/null \
   || [ "$(gcloud config get-value project 2>/dev/null)" != "$PROJECT_ID" ]; then
  gcp_fail "could not select GCP project '$PROJECT_ID'"
fi
# A different account activated earlier (the configured service account
# changed) stays cached until revoked
[ -z "$PRIOR_SA" ] || [ "$PRIOR_SA" = "$SA_CFG" ] || gcloud auth revoke "$PRIOR_SA" >/dev/null 2>&1 || true
export GOOGLE_APPLICATION_CREDENTIALS="$ADC_KEY"
# Persist for the rest of the session: snippets run in short-lived shells, and
# Python clients in later commands need GOOGLE_APPLICATION_CREDENTIALS too
if [ -n "$CLAUDE_ENV_FILE" ]; then
  sed -i '/^unset GOOGLE_APPLICATION_CREDENTIALS$/d' "$CLAUDE_ENV_FILE" 2>/dev/null || true
  grep -qxF "export GOOGLE_APPLICATION_CREDENTIALS=\"$ADC_KEY\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "export GOOGLE_APPLICATION_CREDENTIALS=\"$ADC_KEY\"" >> "$CLAUDE_ENV_FILE"
fi
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
