# Multi-Provider Setup

A repo may need access to multiple cloud providers (e.g., GCP for BigQuery and AWS for S3). This skill supports this with a few conventions.

## Config Format

When a second provider is added, convert `.cloud-config.json` from a single-provider object to a `providers` array:

```json
{
  "providers": [
    {
      "provider": "gcp",
      "project_id": "my-gcp-project",
      "service_account": "claude-agent@my-gcp-project.iam.gserviceaccount.com",
      "roles": ["roles/storage.objectAdmin"],
      "key_ids": {"alice@example.com": "0123456789abcdef0123456789abcdef01234567"},
      "created_at": "2025-03-15T10:00:00Z"
    },
    {
      "provider": "aws",
      "project_id": "123456789012",
      "service_account": "claude-agents-my-repo-3f9a1c",
      "iam_user_prefix": "claude-agent-my-repo-3f9a1c",
      "roles": ["AmazonS3FullAccess"],
      "created_at": "2025-03-16T14:00:00Z"
    }
  ]
}
```

## Credential File Naming

With multiple providers, include the provider in the filename:

```
.cloud-credentials.<provider>.<email>.enc
```

For example: `.cloud-credentials.gcp.alice@example.com.enc` and `.cloud-credentials.aws.alice@example.com.enc`.

## Backward Compatibility

If `.cloud-config.json` has a top-level `provider` field (single-provider format), treat it as-is — no migration needed until a second provider is added. When adding a second provider:

1. Read the existing single-provider config and the new provider's reference file.
2. **Provision the new provider** exactly as First-Time Setup does for it: resolve that provider's encryption key first (stop if missing), propose roles and get the user's approval, get its bootstrap token, create the identity, grant only the approved roles, generate its credentials, and encrypt them to `.cloud-credentials.<new-provider>.<email>.enc`. The creation snippet records the new identity's names in `.cloud-setup-pending.json` (make sure `.gitignore` has `/.cloud-setup-pending.json` next to `/credentials.json`). Keep `credentials.json` and that file until step 4 has written the new entry: if the run is interrupted before then, the next session finds them and rolls the new identity back ("Recovering an Interrupted Run" in SKILL.md); a failure in this step needs the provider's "Rollback a Failed Setup" too.
   Until step 4, `.cloud-config.json` still describes only the old provider, and the reference snippets read config only for an entry whose `provider` matches, so they find nothing for the new one. Set the new provider's identifiers at the top of every snippet you run, since each snippet may run in a fresh shell: GCP `PROJECT_ID` and `SA_EMAIL`; AWS `GROUP_NAME`, `USER_PREFIX`, and `AWS_REGION`; Azure `SUBSCRIPTION_ID`, `TENANT_ID`, and `APP_ID`. Keep them for step 4.
3. Rename existing `.cloud-credentials.<email>.enc` files to `.cloud-credentials.<provider>.<email>.enc` with `git mv`, without committing yet: a commit holding only the rename would leave a checkout whose single-provider config no longer matches its file names. The rename is committed together with the new provider's `.enc` and the rewritten config (step 6); renaming does not change the files' contents, and the hooks' age check reads `git log --follow --diff-filter=AM`, which follows the rename and ignores it, so a migrated key keeps its real age.
4. Rewrite `.cloud-config.json` to the `providers` array format, with one entry for the existing provider and one for the new one, and keep a top-level `unrevoked` list unchanged at the root: its entries already name their provider, and they are the only record of credentials still to revoke. Move everything else of the old top-level object (including `key_ids`, `rotating`, `revoke_pending` and `revoked_early`) into the existing provider's entry; for example `jq --argjson new "$NEW_ENTRY" '{providers: [del(.unrevoked), $new]} + (if .unrevoked then {unrevoked} else {} end)' .cloud-config.json`. Each entry has its own `roles` and `created_at`. A new GCP or Azure entry also gets its `key_ids`: the GCP key ID or the Azure secret's `keyId`, read from `credentials.json` (`jq -r .private_key_id` for GCP, `jq -r .keyId` for Azure; it is not secret). Keep the plaintext and the pending record until step 6 has committed everything: until then they mark the migration as unfinished, so an interrupted run is recovered (finishing steps 3 and 4) rather than read as a missing credential.
5. Replace `.claude/hooks/cloud-auth.sh` with the multi-provider hook below.
6. Verify each provider's credentials with its smoke test, then commit all changes together (the rename, the new `.enc`, the config and the hook). Only after that commit, delete the plaintext and the pending record: `rm -f credentials.json .cloud-setup-pending.json`.

Other team members then add the new provider for themselves through Add Team Member, one provider at a time.

## Authentication

When the config uses the `providers` array format, authenticate **all** providers during the Authenticate flow (or in the SessionStart hook). Each provider uses its own credentials key env var, falling back to `CLOUD_CREDENTIALS_KEY`.

## Multi-Provider SessionStart Hook

When converting to multi-provider, replace the single-provider `cloud-auth.sh` with a script that iterates over all providers. The hook should:

1. Read the `providers` array from `.cloud-config.json`
2. For each provider entry, resolve the provider-specific credentials key
3. Look for the provider-prefixed credential file: `.cloud-credentials.<provider>.<email>.enc`
4. Decrypt and activate using the provider-specific commands from each reference file
5. Install each provider's CLI if missing

```bash
#!/bin/bash
set -e

# Claude Code on the Web only (each session is its own container); see the
# single-provider hook in references/gcp.md for why it skips local machines.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then exit 0; fi
# Hooks run in the session's current directory, which may be a subdirectory
cd "${CLAUDE_PROJECT_DIR:-.}"

# The loop decrypts each provider's key to /tmp/credentials.json and may then
# spend minutes installing a CLI; remove the plaintext however the hook ends
# (timeout, interruption, a failing command). The GCP ADC copy is separate.
# If GCP may be configured but this run does not activate it, also undo an
# earlier activation in this container (stored account, ADC key, export), so a
# removed passphrase or broken file disables repository auth
clear_prior_gcp() {
  local G K=/tmp/gcp-adc-credentials.json
  if [ -f "$K" ]; then
    for G in gcloud /home/user/google-cloud-sdk/bin/gcloud; do
      command -v "$G" >/dev/null 2>&1 && { "$G" auth revoke "$(jq -r .client_email "$K" 2>/dev/null)" >/dev/null 2>&1 || true; break; }
    done
    rm -f "$K"
  fi
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
    sed -i '/GOOGLE_APPLICATION_CREDENTIALS/d' "$CLAUDE_ENV_FILE"
    echo "unset GOOGLE_APPLICATION_CREDENTIALS" >> "$CLAUDE_ENV_FILE"
  fi
}
# Likewise for AWS (the persisted key exports) and Azure (az's cached login)
clear_prior_aws() {
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
    sed -i '/^export AWS_ACCESS_KEY_ID=/d; /^export AWS_SECRET_ACCESS_KEY=/d; /^export AWS_DEFAULT_REGION=/d' "$CLAUDE_ENV_FILE"
    echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION" >> "$CLAUDE_ENV_FILE"
  fi
}
clear_prior_az() { command -v az >/dev/null 2>&1 && az logout >/dev/null 2>&1 || true; }
trap 'rm -f /tmp/credentials.json
      [ "${GCP_CONFIGURED:-}" != 1 ] || [ "${GCP_OK:-}" = 1 ] || clear_prior_gcp
      [ "${AWS_CONFIGURED:-}" != 1 ] || [ "${AWS_OK:-}" = 1 ] || clear_prior_aws
      [ "${AZ_CONFIGURED:-}" != 1 ] || [ "${AZ_OK:-}" = 1 ] || clear_prior_az' EXIT

# Claude Code on the Web can preset CLOUDSDK_AUTH_ACCESS_TOKEN, which outranks
# the activated service account. Clear it for the session whenever GCP may be
# configured: when GCP is among the providers, and when the config is missing
# or unreadable (fail closed rather than run as the ambient principal).
clear_gcp_token() {
  GCP_CONFIGURED=1
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  if [ -n "$CLAUDE_ENV_FILE" ]; then
    grep -qxF "unset CLOUDSDK_AUTH_ACCESS_TOKEN" "$CLAUDE_ENV_FILE" 2>/dev/null || \
      echo "unset CLOUDSDK_AUTH_ACCESS_TOKEN" >> "$CLAUDE_ENV_FILE"
  fi
}

# The IAM user this member should be (see "IAM Names" in references/aws.md)
expected_iam_user() {   # $1 = email, $2 = user prefix
  local h n
  h=$(printf '%s' "$1" | sha256sum | cut -c1-8)
  if [ "$2" = "claude-agent" ]; then
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,_-]/-/g')"
  else
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,.@_-]/-/g')"
    [ "$n" = "$2-$1" ] || n="${n:0:55}-$h"
  fi
  [ ${#n} -le 64 ] || n="${n:0:55}-$h"
  printf '%s' "$n"
}

CONFIG=".cloud-config.json"
# A missing or unreadable config fails closed for every provider
all_configured() { AWS_CONFIGURED=1; AZ_CONFIGURED=1; clear_gcp_token; }
if [ ! -f "$CONFIG" ]; then all_configured; exit 0; fi

PROVIDER_COUNT=$(jq -r '.providers | length' "$CONFIG" 2>/dev/null) || { all_configured; exit 0; }
if [ -z "$PROVIDER_COUNT" ] || [ "$PROVIDER_COUNT" = "null" ]; then all_configured; exit 0; fi
if jq -e 'any(.providers[]; .provider == "gcp")' "$CONFIG" >/dev/null 2>&1; then clear_gcp_token; fi
jq -e 'any(.providers[]; .provider == "aws")' "$CONFIG" >/dev/null 2>&1 && AWS_CONFIGURED=1
jq -e 'any(.providers[]; .provider == "azure")' "$CONFIG" >/dev/null 2>&1 && AZ_CONFIGURED=1

USER_EMAIL=$(git config user.email 2>/dev/null || true)
if [ -z "$USER_EMAIL" ]; then exit 0; fi

for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
  PROVIDER=$(jq -r ".providers[$i].provider" "$CONFIG" 2>/dev/null) || continue
  ENC_FILE=".cloud-credentials.${PROVIDER}.${USER_EMAIL}.enc"
  if [ ! -f "$ENC_FILE" ]; then continue; fi

  case "$PROVIDER" in
    gcp)   KEY="${GCP_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    aws)   KEY="${AWS_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    azure) KEY="${AZURE_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    *)     KEY="$CLOUD_CREDENTIALS_KEY" ;;
  esac
  if [ -z "$KEY" ]; then continue; fi

  # Per-file credential age, as in the Authenticate workflow
  COMMIT_TS=$(git log --follow --diff-filter=AM -1 --format=%ct -- "$ENC_FILE" 2>/dev/null || true)
  if [ -z "$COMMIT_TS" ]; then
    COMMIT_TS=$(date -d "$(jq -r ".providers[$i].created_at // .created_at // empty" "$CONFIG")" +%s 2>/dev/null || true)
  fi
  if [ -n "$COMMIT_TS" ] && [ "$(( ( $(date +%s) - COMMIT_TS ) / 86400 ))" -gt 180 ]; then
    echo "NOTE: $PROVIDER credentials in $ENC_FILE are over 180 days old — consider rotating (see Credential Rotation)."
  fi

  # Decrypt with restrictive permissions
  if ! (umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
    -pass stdin -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null); then
    echo "WARNING: Failed to decrypt $PROVIDER credentials — check key or .enc file integrity."
    rm -f /tmp/credentials.json
    continue
  fi

  # Activate using provider-specific commands (install CLI + authenticate)
  # Each provider block is guarded so one failure doesn't block others
  case "$PROVIDER" in
    gcp)
      if ! command -v gcloud &>/dev/null; then
        for dir in /home/user/google-cloud-sdk/bin /usr/lib/google-cloud-sdk/bin /usr/local/google-cloud-sdk/bin; do
          if [ -x "$dir/gcloud" ]; then export PATH="$dir:$PATH"; break; fi
        done
      fi
      if ! command -v gcloud &>/dev/null; then
        INSTALLER=$(curl -sSL https://sdk.cloud.google.com 2>/dev/null) || true
        if [ -z "$INSTALLER" ] || ! echo "$INSTALLER" | bash -s -- --disable-prompts --install-dir=/home/user; then
          echo "WARNING: gcloud SDK install failed — skipping GCP auth."
          rm -f /tmp/credentials.json; continue
        fi
        export PATH="/home/user/google-cloud-sdk/bin:$PATH"
      fi
      # Only a key for the configured service account (not a stale or copied one)
      SA_CFG=$(jq -r ".providers[$i].service_account // empty" "$CONFIG")
      if [ -z "$SA_CFG" ] || [ "$(jq -r '.client_email // empty' /tmp/credentials.json)" != "$SA_CFG" ]; then
        echo "WARNING: $ENC_FILE is not a key for ${SA_CFG:-the configured service account}; skipping GCP."
        rm -f /tmp/credentials.json; continue
      fi
      if ! gcloud auth activate-service-account --key-file=/tmp/credentials.json 2>/dev/null; then
        echo "WARNING: gcloud auth failed — skipping GCP."
        rm -f /tmp/credentials.json; continue
      fi
      # Confirm the configured project took; otherwise an earlier cached project
      # would stay active, so log the account out and skip GCP.
      GCP_PROJECT=$(jq -r ".providers[$i].project_id // empty" "$CONFIG" 2>/dev/null)
      if [ -z "$GCP_PROJECT" ] || ! gcloud config set project "$GCP_PROJECT" 2>/dev/null \
         || [ "$(gcloud config get-value project 2>/dev/null)" != "$GCP_PROJECT" ]; then
        echo "WARNING: could not select GCP project '$GCP_PROJECT' — skipping GCP."
        gcloud auth revoke "$(jq -r .client_email /tmp/credentials.json)" 2>/dev/null || true
        rm -f /tmp/credentials.json; continue
      fi
      # Preserve a GCP-specific key + ADC for the session so Python Google
      # client libraries (which read GOOGLE_APPLICATION_CREDENTIALS, not the
      # gcloud CLI auth store) work. The shared cleanup below removes
      # /tmp/credentials.json, so copy to a stable, private path first.
      GCP_ADC_KEY="/tmp/gcp-adc-credentials.json"
      (umask 077 && cp /tmp/credentials.json "$GCP_ADC_KEY")
      export GOOGLE_APPLICATION_CREDENTIALS="$GCP_ADC_KEY"
      if [ -n "$CLAUDE_ENV_FILE" ]; then
        GCLOUD_BIN="$(dirname "$(command -v gcloud)")"
        grep -qxF "export PATH=\"$GCLOUD_BIN:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
          echo "export PATH=\"$GCLOUD_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
        sed -i '/^unset GOOGLE_APPLICATION_CREDENTIALS$/d' "$CLAUDE_ENV_FILE" 2>/dev/null || true
        grep -qxF "export GOOGLE_APPLICATION_CREDENTIALS=\"$GCP_ADC_KEY\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
          echo "export GOOGLE_APPLICATION_CREDENTIALS=\"$GCP_ADC_KEY\"" >> "$CLAUDE_ENV_FILE"
      fi
      GCP_OK=1
      ;;
    aws)
      if ! command -v aws &>/dev/null; then
        for dir in /home/user/bin /usr/local/bin /home/user/aws-cli/v2/current/bin; do
          if [ -x "$dir/aws" ]; then export PATH="$dir:$PATH"; break; fi
        done
      fi
      if ! command -v aws &>/dev/null; then
        if curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip 2>/dev/null && \
           unzip -q /tmp/awscliv2.zip -d /tmp && \
           /tmp/aws/install --install-dir /home/user/aws-cli --bin-dir /home/user/bin; then
          export PATH="/home/user/bin:$PATH"
        else
          echo "WARNING: AWS CLI install failed — skipping AWS auth."
          rm -rf /tmp/awscliv2.zip /tmp/aws /tmp/credentials.json; continue
        fi
        rm -rf /tmp/awscliv2.zip /tmp/aws
      fi
      export AWS_ACCESS_KEY_ID=$(jq -r .access_key_id /tmp/credentials.json)
      export AWS_SECRET_ACCESS_KEY=$(jq -r .secret_access_key /tmp/credentials.json)
      export AWS_DEFAULT_REGION=$(jq -r '.region // empty' /tmp/credentials.json)
      # Long-lived IAM-user keys: drop any stale STS session token or profile
      unset AWS_SESSION_TOKEN AWS_PROFILE
      # Only as this member's user in this repo's account (a stale or copied
      # file could hold another account's or another user's keys)
      ACCOUNT=$(jq -r ".providers[$i].project_id // empty" "$CONFIG")
      PREFIX=$(jq -r ".providers[$i].iam_user_prefix // empty" "$CONFIG"); PREFIX="${PREFIX:-claude-agent}"
      WANT_USER=$(expected_iam_user "$USER_EMAIL" "$PREFIX")
      read -r CALLER CALLER_ARN <<< "$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null || true)"
      if [ -z "$ACCOUNT" ] || [ "${CALLER:-}" != "$ACCOUNT" ] || [ "${CALLER_ARN:-}" != "arn:aws:iam::$ACCOUNT:user/$WANT_USER" ]; then
        echo "WARNING: $ENC_FILE is for ${CALLER_ARN:-an unknown identity (lookup failed)}, not user $WANT_USER in account ${ACCOUNT:-(not configured)}; not activating it."
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
        rm -f /tmp/credentials.json; continue
      fi
      if [ -n "$CLAUDE_ENV_FILE" ]; then
        sed -i '/^unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION$/d' "$CLAUDE_ENV_FILE" 2>/dev/null || true
        echo "export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'" >> "$CLAUDE_ENV_FILE"
        echo "export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'" >> "$CLAUDE_ENV_FILE"
        echo "unset AWS_SESSION_TOKEN AWS_PROFILE" >> "$CLAUDE_ENV_FILE"
        echo "export AWS_DEFAULT_REGION='$AWS_DEFAULT_REGION'" >> "$CLAUDE_ENV_FILE"
        AWS_BIN="$(dirname "$(command -v aws)")"
        grep -qxF "export PATH=\"$AWS_BIN:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
          echo "export PATH=\"$AWS_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
      fi
      ;;
    azure)
      if ! command -v az &>/dev/null; then
        for dir in /usr/bin /usr/local/bin /home/user/bin; do
          if [ -x "$dir/az" ]; then export PATH="$dir:$PATH"; break; fi
        done
      fi
      if ! command -v az &>/dev/null; then
        if ! curl -sSL https://aka.ms/InstallAzureCLIDeb | sudo bash; then
          echo "WARNING: Azure CLI install failed — skipping Azure auth."
          rm -f /tmp/credentials.json; continue
        fi
      fi
      # Only a credential for the configured application (not a stale or copied one)
      APP_CFG=$(jq -r ".providers[$i].service_account // empty" "$CONFIG")
      if [ -z "$APP_CFG" ] || [ "$(jq -r '.appId // empty' /tmp/credentials.json)" != "$APP_CFG" ]; then
        echo "WARNING: $ENC_FILE is not for application ${APP_CFG:-configured}; skipping Azure."
        rm -f /tmp/credentials.json; continue
      fi
      if ! az login --service-principal \
        --username "$(jq -r .appId /tmp/credentials.json)" \
        --password "$(jq -r .password /tmp/credentials.json)" \
        --tenant "$(jq -r .tenant /tmp/credentials.json)" 2>/dev/null; then
        echo "WARNING: az login failed — skipping Azure."
        rm -f /tmp/credentials.json; continue
      fi
      if ! az account set --subscription "$(jq -r ".providers[$i].project_id" "$CONFIG" 2>/dev/null)" 2>/dev/null; then
        echo "WARNING: could not select the configured Azure subscription — logging out of Azure."
        az logout 2>/dev/null || true
        rm -f /tmp/credentials.json; continue
      fi
      # Persist the az location for the session, as the GCP and AWS branches do
      if [ -n "$CLAUDE_ENV_FILE" ]; then
        AZ_BIN="$(dirname "$(command -v az)")"
        grep -qxF "export PATH=\"$AZ_BIN:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
          echo "export PATH=\"$AZ_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
      fi
      ;;
  esac

  rm -f /tmp/credentials.json
  case "$PROVIDER" in gcp) GCP_OK=1 ;; aws) AWS_OK=1 ;; azure) AZ_OK=1 ;; esac
  echo "$PROVIDER credentials activated for $USER_EMAIL"
done
```
