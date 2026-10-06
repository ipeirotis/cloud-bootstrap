#!/bin/bash
# Revoke a credential this skill just created but cannot use (verification or
# encryption failed), then delete its plaintext. Every value is re-resolved from
# credentials.json, .cloud-config.json and the provider, so this works from any
# shell. Run from the repository root:
#
#   bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh PROVIDER [key|member]
#
#   PROVIDER  gcp | aws | azure
#   key       (default) revoke only the new key or secret
#   member    AWS only: also delete the member's new IAM user (Add Team Member)
#
# Needs the bootstrap token for the provider: TOKEN (GCP), the AWS bootstrap
# credentials in the environment, or GRAPH_TOKEN (Azure). Optional overrides:
# CRED_ID (the GCP key resource name or ID, the AWS access key ID, or the Azure
# secret keyId) when credentials.json is missing or unreadable. A GCP or Azure
# CRED_ID is revoked only when it is provably this member's: recorded for them
# in .cloud-config.json, the key in credentials.json, an Azure secret labelled
# for them, or (CRED_ID_FROM_RESPONSE=1, set by the skill's own snippets) taken
# from this run's create response. Any other ID is recorded as ambiguous.
#
# If revocation fails, the credential's non-secret identifier is appended to
# "unrevoked" in .cloud-config.json, which must then be committed, so the record
# outlives this checkout. Exit status: 0 revoked, 1 recorded as unrevoked.
set -u
PROVIDER="${1:?usage: discard-credential.sh gcp|aws|azure [key|member]}"
MODE="${2:-key}"
CREDS=credentials.json
CONFIG=.cloud-config.json
USER_EMAIL=$(git config user.email 2>/dev/null || true)

cfg() {   # provider-aware read of one config field
  jq -r --arg p "$PROVIDER" "(if .providers then (.providers[] | select(.provider == \$p)) else select(.provider == \$p) end) | .$1 // empty" "$CONFIG" 2>/dev/null
}
cred() { jq -r "$1 // empty" "$CREDS" 2>/dev/null; }

record_unrevoked() {   # $1 = identifier, $2 = note
  echo "WARNING: could not revoke $PROVIDER credential $1 ($2)."
  if [ -f "$CONFIG" ]; then
    jq --arg p "$PROVIDER" --arg id "$1" --arg n "$2" --arg m "$USER_EMAIL" \
       --arg t "$(date -u +%FT%TZ)" \
       '.unrevoked = ((.unrevoked // []) + [{provider: $p, id: $id, member: $m, note: $n, at: $t}])' \
       "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG" \
      && echo "Recorded under \"unrevoked\" in $CONFIG: commit it, and revoke the credential by hand." \
      || { rm -f "$CONFIG.tmp"; KEEP_PLAINTEXT=1
           echo "ERROR: could not record it in $CONFIG either: note \"$PROVIDER $1\" and revoke it by hand."
           echo "credentials.json is kept, so the next session still sees this interrupted run."; }
  else
    # Only during first-time setup: its rollback deletes the whole identity,
    # which removes this credential too.
    echo "No $CONFIG yet: run the provider's setup rollback, which deletes the identity and this credential with it."
  fi
}

STATUS=1; REVOKED_ID=""; KEEP_PLAINTEXT=""
# A credential the config records for ANOTHER member (current key, key being
# rotated, or one queued for revocation) is never this run's: a stale or
# mistyped CRED_ID must not revoke a teammate's working key or secret
owned_by_me() {   # $1 = key ID: recorded in the config for this member
  [ -f "$CONFIG" ] || return 1
  jq -e --arg p "$PROVIDER" --arg e "$USER_EMAIL" --arg id "${1##*/}" '
    (if .providers then (.providers[] | select(.provider == $p)) else . end)
    | [(.key_ids // {}), (.rotating // {}), (.revoke_pending // {})][]
    | .[$e] // empty | (if type == "array" then .[] else . end) | tostring | split("/") | last
    | select(. == $id)' "$CONFIG" >/dev/null 2>&1
}
record_ambiguous() {   # $1 = ID whose owner cannot be established: keep it, never delete
  echo "ERROR: $PROVIDER credential $1 cannot be tied to $USER_EMAIL (not in credentials.json or this member's records); not revoking it."
  if [ -f "$CONFIG" ]; then
    jq --arg p "$PROVIDER" --arg id "$1" --arg m "$USER_EMAIL" --arg t "$(date -u +%FT%TZ)" \
      '.unrevoked = ((.unrevoked // []) + [{provider: $p, id: $id, member: $m, ambiguous: true,
         note: "CRED_ID override whose owner could not be confirmed", at: $t}])' \
      "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG" \
      && echo "Recorded as ambiguous under \"unrevoked\" in $CONFIG; check who owns it before revoking it by hand." \
      || { rm -f "$CONFIG.tmp"; echo "ERROR: could not record it either; note \"$PROVIDER $1\"."; }
  fi
  exit 1
}
owned_by_other() {   # $1 = key ID (bare, or a GCP resource name)
  [ -f "$CONFIG" ] || return 1
  jq -e --arg p "$PROVIDER" --arg e "$USER_EMAIL" --arg id "${1##*/}" '
    (if .providers then (.providers[] | select(.provider == $p)) else . end)
    | [(.key_ids // {}), (.rotating // {}), (.revoke_pending // {})][]
    | to_entries[] | select(.key != $e)
    | (.value | if type == "array" then .[] else . end) | tostring | split("/") | last
    | select(. == $id)' "$CONFIG" >/dev/null 2>&1
}
case "$PROVIDER" in
  gcp)
    # Once GCP is configured, its project and account decide (shell values
    # from another setup are refused); before that, the caller's values
    CFG_P="$(cfg project_id)"; CFG_S="$(cfg service_account)"
    if [ -n "$CFG_P$CFG_S" ]; then
      { [ -z "${PROJECT_ID:-}" ] || [ "$PROJECT_ID" = "$CFG_P" ]; } && { [ -z "${SA_EMAIL:-}" ] || [ "$SA_EMAIL" = "$CFG_S" ]; } \
        || { echo "ERROR: PROJECT_ID/SA_EMAIL disagree with .cloud-config.json ($CFG_P, $CFG_S); nothing deleted."; exit 1; }
      PROJECT_ID="$CFG_P"; SA_EMAIL="$CFG_S"
    fi
    ID="${CRED_ID:-$(cred .private_key_id)}"
    if [ -n "$ID" ] && owned_by_other "$ID"; then
      echo "ERROR: GCP key ${ID##*/} is recorded in .cloud-config.json for another member; not deleting it. Check CRED_ID / credentials.json."
      exit 1
    fi
    # An override must be positively this member's (see the header)
    if [ -n "${CRED_ID:-}" ] && [ "${CRED_ID_FROM_RESPONSE:-}" != 1 ] \
       && [ "${CRED_ID##*/}" != "$(cred .private_key_id)" ] && ! owned_by_me "$CRED_ID"; then
      record_ambiguous "$CRED_ID"
    fi
    case "$ID" in
      projects/*) NAME="$ID" ;;
      "") NAME="" ;;
      *) NAME="projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL/keys/$ID" ;;
    esac
    # A full resource name needs nothing else; a bare ID needs the project and
    # service account (checked when the name was built above)
    case "$NAME" in projects/?*/serviceAccounts/?*/keys/?*) ;; *) NAME="" ;; esac
    HTTP=000
    if [ -n "$NAME" ] && [ -n "${TOKEN:-}" ]; then
      # A key created moments ago can read as missing (404) for a minute or
      # more: count 404 as gone only once it persists across retries
      for DELAY in 0 20 40 60; do
        sleep "$DELAY"
        HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "https://iam.googleapis.com/v1/$NAME" \
          -H "Authorization: Bearer $TOKEN")
        [ "$HTTP" = 404 ] || break
      done
    fi
    # 404 throughout: the key no longer exists (an earlier attempt deleted it)
    if [ "$HTTP" = 200 ] || [ "$HTTP" = 404 ]; then
      echo "GCP key ${NAME##*/} is deleted."; STATUS=0; REVOKED_ID="${NAME##*/}"
    else
      record_unrevoked "${NAME:-unknown key of ${SA_EMAIL:-the service account}}" "new key for $USER_EMAIL"
    fi ;;
  aws)
    AK="${CRED_ID:-$(cred '.access_key_id // .AccessKey.AccessKeyId')}"
    # Only in this repo's account: elsewhere the key lookup reports NoSuchEntity
    # (read below as "already gone") and a same-named user could be deleted
    # The expected account: from the config, or during first-time setup from
    # the pending setup record. Without one, nothing is looked up or deleted.
    ACCOUNT="$(cfg project_id)"
    ACCOUNT="${ACCOUNT:-$(jq -r 'select(.provider == "aws") | .account // empty' .cloud-setup-pending.json 2>/dev/null)}"
    CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
    if [ -z "$ACCOUNT" ] || [ "$CALLER" != "$ACCOUNT" ]; then
      record_unrevoked "${AK:-unknown access key}" "bootstrap credentials are for account ${CALLER:-unknown}, expected ${ACCOUNT:-none configured}"
      # The key ID is recorded (unless that failed): the plaintext must not stay
      [ -n "$KEEP_PLAINTEXT" ] || rm -f "$CREDS" credentials_clean.json
      exit 1
    fi
    # The only user whose keys this script may delete: this member's, as the
    # setup record names it or as references/aws.md ("IAM Names") derives it
    # from the email. A stale credentials.json or a mistyped CRED_ID can name a
    # live key of a teammate, which must never be deleted here.
    PEND() { jq -r --arg k "$1" 'select(.provider == "aws") | .[$k] // empty' .cloud-setup-pending.json 2>/dev/null; }
    PREFIX="$(cfg iam_user_prefix)"; PREFIX="${PREFIX:-$(PEND user_prefix)}"; PREFIX="${PREFIX:-claude-agent}"
    H=$(printf '%s' "$USER_EMAIL" | sha256sum | cut -c1-8)
    if [ "$PREFIX" = "claude-agent" ]; then
      N="$PREFIX-$(printf '%s' "$USER_EMAIL" | sed 's/[^A-Za-z0-9+=,_-]/-/g')"
    else
      N="$PREFIX-$(printf '%s' "$USER_EMAIL" | sed 's/[^A-Za-z0-9+=,.@_-]/-/g')"
      [ "$N" = "$PREFIX-$USER_EMAIL" ] || N="${N:0:55}-$H"
    fi
    [ ${#N} -le 64 ] || N="${N:0:55}-$H"
    PEND_USER="$(PEND iam_user)"; N="${PEND_USER:-$N}"
    # The key's owner, from AWS itself
    U=""; LOOKUP=""; RECHECK=""
    if [ -n "$AK" ]; then
      RECHECK=key
      if OUT=$(aws iam get-access-key-last-used --access-key-id "$AK" --query UserName --output text 2>&1)
      then U="$OUT"; else LOOKUP="$OUT"; fi
    elif [ "$MODE" = key ] && [ -n "$(cfg "rotating[\"$USER_EMAIL\"]")" ]; then
      # Rotation with no key ID (interrupted before create-access-key's output
      # was saved). Step 3 recorded the current key in rotating; every other
      # key of this member's user that the config does not name is the lost
      # replacement, which nobody holds.
      KNOWN=$(jq -r --arg e "$USER_EMAIL" '(if .providers then (.providers[] | select(.provider == "aws")) else . end)
        | [.rotating[$e] // empty] + ((.revoke_pending[$e] // []) | if type == "string" then [.] else . end) | .[]' "$CONFIG")
      if KEYS=$(aws iam list-access-keys --user-name "$N" --query 'AccessKeyMetadata[].AccessKeyId' --output text); then
        # The lost replacement is a key the config does not name. Nobody holds
        # its secret, but an overlapping rotation of this member could have
        # created such a key too, so record the candidates instead of deleting
        AK=""; UNREC=""
        for k in $KEYS; do
          printf '%s\n' $KNOWN | grep -qxF "$k" && continue
          AK="$AK $k"
          jq --arg id "$k" --arg m "$USER_EMAIL" --arg t "$(date -u +%FT%TZ)" \
            '.unrevoked = ((.unrevoked // []) + [{provider: "aws", id: $id, member: $m, ambiguous: true,
               note: "unrecorded key from an interrupted rotation, or one an overlapping rotation created", at: $t}])' \
            "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG" \
            || { rm -f "$CONFIG.tmp"; UNREC="$UNREC $k"; }
        done
        if [ -n "$UNREC" ]; then
          # Nothing durable names these keys: stop with them on screen, and
          # keep the plaintext so the interrupted run stays visible
          echo "ERROR: could not record these keys of $N in $CONFIG (fix the file, then add them under \"unrevoked\" by hand):$UNREC"
          exit 1
        fi
        if [ -n "$AK" ]; then
          echo "Unrecorded key(s) of $N:$AK (recorded as ambiguous under \"unrevoked\"; commit $CONFIG)."
          echo "Delete each one no rotation of yours is using: aws iam delete-access-key --user-name $N --access-key-id <id>"
        else
          echo "No unrecorded key of $N exists; nothing was created."; STATUS=0
        fi
        rm -f "$CREDS" credentials_clean.json; exit "$STATUS"
      fi
      LOOKUP="could not list keys of $N"; AK="(new key of $N)"
    elif [ "$MODE" = member ]; then
      # No key ID (interrupted before create-access-key's output was saved):
      # the new member's user is the repo-scoped name for this email, as
      # references/aws.md derives it. A credentials.json exists only once that
      # user was created by this run, so it is this run's user.
      RECHECK=user
      if OUT=$(aws iam get-user --user-name "$N" --query User.UserName --output text 2>&1)
      then U="$OUT"; AK="(all keys of $N)"; else LOOKUP="$OUT"; AK="(user $N)"; fi
    fi
    # IAM is eventually consistent: a key or user created moments ago can read
    # as missing. Count it gone only if the absence holds for about a minute
    if [ -z "$U" ] && [ -n "$RECHECK" ] && printf '%s' "$LOOKUP" | grep -q NoSuchEntity; then
      for D in 20 20 20; do
        sleep "$D"
        if [ "$RECHECK" = key ]; then
          OUT=$(aws iam get-access-key-last-used --access-key-id "$AK" --query UserName --output text 2>&1)
        else
          OUT=$(aws iam get-user --user-name "$N" --query User.UserName --output text 2>&1)
        fi && { U="$OUT"; LOOKUP=""; [ "$RECHECK" = key ] || AK="(all keys of $N)"; break; }
        LOOKUP="$OUT"; printf '%s' "$OUT" | grep -q NoSuchEntity || break
      done
    fi
    if [ -z "$U" ] && printf '%s' "$LOOKUP" | grep -q NoSuchEntity; then
      # The key (or its user) no longer exists: an earlier attempt removed it
      echo "AWS access key $AK no longer exists."; STATUS=0; REVOKED_ID="$AK"
    elif [ -n "$U" ] && [ "$U" != "None" ] && [ "$U" != "$N" ]; then
      echo "ERROR: access key $AK belongs to IAM user $U, not this member's user $N; nothing deleted."
      echo "credentials.json or CRED_ID names someone else's key: find this run's new key of $N and revoke it by hand."
    elif [ -n "$U" ] && [ "$U" != "None" ]; then
      OK=1
      if [ "$MODE" = member ]; then
        for k in $(aws iam list-access-keys --user-name "$U" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
          aws iam delete-access-key --user-name "$U" --access-key-id "$k" || OK=0
        done
        for g in $(aws iam list-groups-for-user --user-name "$U" --query 'Groups[].GroupName' --output text); do
          aws iam remove-user-from-group --group-name "$g" --user-name "$U" || OK=0
        done
        aws iam delete-user --user-name "$U" || OK=0
      else
        aws iam delete-access-key --user-name "$U" --access-key-id "$AK" || OK=0
      fi
      if [ "$OK" = 1 ]; then echo "Revoked AWS access key $AK${MODE:+ ($MODE)}."; STATUS=0; REVOKED_ID="$AK"
      else record_unrevoked "$AK" "IAM user $U, mode $MODE"; fi
    else
      record_unrevoked "${AK:-unknown access key}" "owner could not be looked up"
    fi ;;
  azure)
    # The application: the configured one (or, before config exists, the setup
    # record's). A credentials.json naming a different app is stale or copied
    # from elsewhere: refuse rather than remove another application's secret.
    EXPECT_APP="$(cfg service_account)"
    EXPECT_APP="${EXPECT_APP:-$(jq -r 'select(.provider == "azure") | .app_id // empty' .cloud-setup-pending.json 2>/dev/null)}"
    APP_ID="$(cred .appId)"
    if [ -n "$APP_ID" ] && [ -n "$EXPECT_APP" ] && [ "$APP_ID" != "$EXPECT_APP" ]; then
      echo "ERROR: credentials.json is for application $APP_ID, but this repo's is $EXPECT_APP; nothing removed. Check the file."
      exit 1
    fi
    APP_ID="${APP_ID:-$EXPECT_APP}"
    OBJECT_ID="${OBJECT_ID:-}"
    # A supplied or inherited object ID may be another application's: use it
    # only when it resolves to APP_ID, else look the application up by APP_ID
    if [ -n "$OBJECT_ID" ]; then
      GOT_APP=""
      if [ -n "$APP_ID" ] && [ -n "${GRAPH_TOKEN:-}" ]; then
        GOT_APP=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
          -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.appId // empty')
      fi
      [ -n "$GOT_APP" ] && [ "$GOT_APP" = "$APP_ID" ] || OBJECT_ID=""
    fi
    if [ -z "$OBJECT_ID" ] && [ -n "$APP_ID" ] && [ -n "${GRAPH_TOKEN:-}" ]; then
      OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
        --data-urlencode "\$filter=appId eq '$APP_ID'" \
        -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
    fi
    # The new secret: given, else the keyId stored with the credential, else
    # (older credentials) the newest secret carrying this member's label
    KID="${CRED_ID:-${NEW_SECRET_KEY_ID:-$(cred .keyId)}}"
    if [ -n "$KID" ] && owned_by_other "$KID"; then
      echo "ERROR: Azure secret $KID is recorded in .cloud-config.json for another member; not removing it. Check CRED_ID / credentials.json."
      exit 1
    fi
    # A secret labelled for another member is theirs, whatever the config says
    LBL=""
    if [ -n "$KID" ] && [ -n "$OBJECT_ID" ] && LBL=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
         -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r --arg k "$KID" '.passwordCredentials[] | select(.keyId == $k) | .displayName // empty') \
       && [ -n "$LBL" ] && [ "$LBL" != "claude-code-$USER_EMAIL" ]; then
      echo "ERROR: Azure secret $KID is labelled \"$LBL\", not this member's; not removing it."
      exit 1
    fi
    # An override must be positively this member's (see the header)
    if [ -n "${CRED_ID:-}" ] && [ "${CRED_ID_FROM_RESPONSE:-}" != 1 ] && [ "$CRED_ID" != "$(cred .keyId)" ] \
       && [ "$LBL" != "claude-code-$USER_EMAIL" ] && ! owned_by_me "$CRED_ID"; then
      record_ambiguous "$CRED_ID"
    fi
    if [ -z "$KID" ] && [ -n "$OBJECT_ID" ]; then
      KID=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
        -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r --arg n "claude-code-$USER_EMAIL" \
        '[.passwordCredentials[] | select(.displayName == $n)] | sort_by(.startDateTime) | last | .keyId // empty')
    fi
    HTTP=000
    if [ -n "$OBJECT_ID" ] && [ -n "$KID" ]; then
      HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
        "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/removePassword" \
        -H "Authorization: Bearer $GRAPH_TOKEN" -H "Content-Type: application/json" \
        -d "{\"keyId\": \"$KID\"}")
    fi
    # Not 204: if the app no longer lists the secret, an earlier attempt removed it
    if [ "$HTTP" != 204 ] && [ -n "$OBJECT_ID" ] && [ -n "$KID" ] \
       && APP=$(curl -sS --fail "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
                  -H "Authorization: Bearer $GRAPH_TOKEN") \
       && printf '%s' "$APP" | jq -e --arg k "$KID" 'all(.passwordCredentials[]; .keyId != $k)' >/dev/null; then
      HTTP=gone
    fi
    if [ "$HTTP" = 204 ] || [ "$HTTP" = gone ]; then echo "Azure secret $KID is removed."; STATUS=0; REVOKED_ID="$KID"
    else record_unrevoked "${KID:-secret labelled claude-code-$USER_EMAIL}" "app $APP_ID, HTTP $HTTP"; fi ;;
  *)
    echo "usage: discard-credential.sh gcp|aws|azure [key|member]"; exit 2 ;;
esac

# The deleted credential may still be recorded as this member's current one
# (key_ids) or as an earlier failure (unrevoked); drop those records so the
# config never names a deleted credential
if [ "$STATUS" = 0 ] && [ -f "$CONFIG" ] && [ -n "${REVOKED_ID:-}" ]; then
  jq --arg p "$PROVIDER" --arg e "$USER_EMAIL" --arg id "$REVOKED_ID" '
    def clr: if .key_ids[$e] == $id then del(.key_ids[$e]) else . end;
    .unrevoked = [(.unrevoked // [])[] | select(.provider != $p or (.id | split("/") | last) != $id)]
    | if .unrevoked == [] then del(.unrevoked) else . end
    | if .providers then .providers |= map(if .provider == $p then clr else . end)
      else (if .provider == $p then clr else . end) end' "$CONFIG" > "$CONFIG.tmp" \
    && mv "$CONFIG.tmp" "$CONFIG" \
    || { rm -f "$CONFIG.tmp"; echo "WARNING: $REVOKED_ID is deleted, but $CONFIG could not be updated; remove any entry naming it by hand."; }
fi

if [ -n "$KEEP_PLAINTEXT" ]; then exit 1; fi
rm -f "$CREDS" credentials_clean.json
exit "$STATUS"
