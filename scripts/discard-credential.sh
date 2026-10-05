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
# secret keyId) when credentials.json is missing or unreadable.
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
      || echo "ERROR: could not record it in $CONFIG either: note \"$PROVIDER $1\" and revoke it by hand."
  else
    # Only during first-time setup: its rollback deletes the whole identity,
    # which removes this credential too.
    echo "No $CONFIG yet: run the provider's setup rollback, which deletes the identity and this credential with it."
  fi
}

STATUS=1; REVOKED_ID=""
case "$PROVIDER" in
  gcp)
    PROJECT_ID="${PROJECT_ID:-$(cfg project_id)}"
    SA_EMAIL="${SA_EMAIL:-$(cfg service_account)}"
    ID="${CRED_ID:-$(cred .private_key_id)}"
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
      HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "https://iam.googleapis.com/v1/$NAME" \
        -H "Authorization: Bearer $TOKEN")
    fi
    # 404: the key no longer exists (an earlier attempt deleted it), so it is gone
    if [ "$HTTP" = 200 ] || [ "$HTTP" = 404 ]; then
      echo "GCP key ${NAME##*/} is deleted."; STATUS=0; REVOKED_ID="${NAME##*/}"
    else
      record_unrevoked "${NAME:-unknown key of ${SA_EMAIL:-the service account}}" "new key for $USER_EMAIL"
    fi ;;
  aws)
    AK="${CRED_ID:-$(cred '.access_key_id // .AccessKey.AccessKeyId')}"
    # Only in this repo's account: elsewhere the key lookup reports NoSuchEntity
    # (read below as "already gone") and a same-named user could be deleted
    ACCOUNT="$(cfg project_id)"
    CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
    if [ -n "$ACCOUNT" ] && [ "$CALLER" != "$ACCOUNT" ]; then
      record_unrevoked "${AK:-unknown access key}" "bootstrap credentials are for account ${CALLER:-unknown}, not $ACCOUNT"
      rm -f "$CREDS" credentials_clean.json; exit 1
    fi
    # The key's owner, from AWS itself: correct even when no IAM name is known here
    U=""; LOOKUP=""
    if [ -n "$AK" ]; then
      if OUT=$(aws iam get-access-key-last-used --access-key-id "$AK" --query UserName --output text 2>&1)
      then U="$OUT"; else LOOKUP="$OUT"; fi
    fi
    if [ -z "$U" ] && printf '%s' "$LOOKUP" | grep -q NoSuchEntity; then
      # The key (or its user) no longer exists: an earlier attempt removed it
      echo "AWS access key $AK no longer exists."; STATUS=0; REVOKED_ID="$AK"
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
    APP_ID="$(cred .appId)"; APP_ID="${APP_ID:-$(cfg service_account)}"
    OBJECT_ID="${OBJECT_ID:-}"
    if [ -z "$OBJECT_ID" ] && [ -n "$APP_ID" ] && [ -n "${GRAPH_TOKEN:-}" ]; then
      OBJECT_ID=$(curl -sS --fail -G "https://graph.microsoft.com/v1.0/applications" \
        --data-urlencode "\$filter=appId eq '$APP_ID'" \
        -H "Authorization: Bearer $GRAPH_TOKEN" | jq -r '.value[0].id // empty')
    fi
    # The new secret: given, else the keyId stored with the credential, else
    # (older credentials) the newest secret carrying this member's label
    KID="${CRED_ID:-${NEW_SECRET_KEY_ID:-$(cred .keyId)}}"
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

rm -f "$CREDS" credentials_clean.json
exit "$STATUS"
