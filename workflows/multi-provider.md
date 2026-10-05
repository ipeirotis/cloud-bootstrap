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
2. **Provision the new provider** exactly as First-Time Setup does for it: resolve that provider's encryption key first (stop if missing), propose roles and get the user's approval, get its bootstrap token, create the identity, grant only the approved roles, generate its credentials, and encrypt them to `.cloud-credentials.<new-provider>.<email>.enc`. The creation snippet records the new identity's names in `.cloud-setup-pending.json` (make sure `.gitignore` has `/.cloud-setup-pending.json` next to `/credentials.json`). Keep `credentials.json` and that file until step 3 has written the new entry: if the run is interrupted before then, the next session finds them and rolls the new identity back ("Recovering an Interrupted Run" in SKILL.md); a failure in this step needs the provider's "Rollback a Failed Setup" too.
   Until step 3, `.cloud-config.json` still describes only the old provider, and the reference snippets read config only for an entry whose `provider` matches, so they find nothing for the new one. Set the new provider's identifiers at the top of every snippet you run, since each snippet may run in a fresh shell: GCP `PROJECT_ID` and `SA_EMAIL`; AWS `GROUP_NAME`, `USER_PREFIX`, and `AWS_REGION`; Azure `SUBSCRIPTION_ID`, `TENANT_ID`, and `APP_ID`. Keep them for step 3.
3. Rewrite `.cloud-config.json` to the `providers` array format, with one entry for the existing provider and one for the new one (each with its own `roles` and `created_at`; for a new GCP or Azure entry, also its `key_ids`: the GCP key ID or the Azure secret's `keyId`, read from `credentials.json`: `jq -r .private_key_id` for GCP, `jq -r .keyId` for Azure; it is not secret). Then delete the plaintext and the pending record: `rm -f credentials.json .cloud-setup-pending.json`.
4. Rename existing `.cloud-credentials.<email>.enc` files to `.cloud-credentials.<provider>.<email>.enc` with `git mv`, in a commit that changes nothing else about them. The hooks' age check reads `git log --follow --diff-filter=AM`, which follows the rename and ignores it, so a migrated key keeps its real age.
5. Replace `.claude/hooks/cloud-auth.sh` with the multi-provider hook below.
6. Verify each provider's credentials with its smoke test, then commit all changes together.

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
trap 'rm -f /tmp/credentials.json' EXIT

# Claude Code on the Web can preset CLOUDSDK_AUTH_ACCESS_TOKEN, which outranks
# the activated service account. Clear it for the session whenever GCP may be
# configured: when GCP is among the providers, and when the config is missing
# or unreadable (fail closed rather than run as the ambient principal).
clear_gcp_token() {
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  if [ -n "$CLAUDE_ENV_FILE" ]; then
    grep -qxF "unset CLOUDSDK_AUTH_ACCESS_TOKEN" "$CLAUDE_ENV_FILE" 2>/dev/null || \
      echo "unset CLOUDSDK_AUTH_ACCESS_TOKEN" >> "$CLAUDE_ENV_FILE"
  fi
}

CONFIG=".cloud-config.json"
if [ ! -f "$CONFIG" ]; then clear_gcp_token; exit 0; fi

PROVIDER_COUNT=$(jq -r '.providers | length' "$CONFIG" 2>/dev/null) || { clear_gcp_token; exit 0; }
if [ -z "$PROVIDER_COUNT" ] || [ "$PROVIDER_COUNT" = "null" ]; then clear_gcp_token; exit 0; fi
if jq -e 'any(.providers[]; .provider == "gcp")' "$CONFIG" >/dev/null 2>&1; then clear_gcp_token; fi

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
        grep -qxF "export GOOGLE_APPLICATION_CREDENTIALS=\"$GCP_ADC_KEY\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
          echo "export GOOGLE_APPLICATION_CREDENTIALS=\"$GCP_ADC_KEY\"" >> "$CLAUDE_ENV_FILE"
      fi
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
      # Only in this repo's account (a stale or copied file could hold another's)
      ACCOUNT=$(jq -r ".providers[$i].project_id // empty" "$CONFIG")
      CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
      if [ -z "$ACCOUNT" ] || [ "$CALLER" != "$ACCOUNT" ]; then
        echo "WARNING: $ENC_FILE is for AWS account ${CALLER:-unknown (lookup failed)}, not ${ACCOUNT:-the configured one}; not activating it."
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
        rm -f /tmp/credentials.json; continue
      fi
      if [ -n "$CLAUDE_ENV_FILE" ]; then
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
  echo "$PROVIDER credentials activated for $USER_EMAIL"
done
```
