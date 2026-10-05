# AWS Reference

## User Prerequisites (First-Time Setup)

The user's AWS account needs **IAM full access** or at minimum:
- `iam:CreateGroup`, `iam:CreateUser`, `iam:AddUserToGroup`
- `iam:CreateAccessKey`
- `iam:AttachGroupPolicy` / `iam:PutGroupPolicy`
- for rolling back a failed setup: `iam:ListAccessKeys`, `iam:DeleteAccessKey`, `iam:RemoveUserFromGroup`, `iam:DeleteUser`, `iam:ListAttachedGroupPolicies`, `iam:ListGroupPolicies`, `iam:DetachGroupPolicy`, `iam:DeleteGroupPolicy`, `iam:DeleteGroup`

## Team Member Prerequisites (Adding to Existing Setup)

The user's AWS account needs:
- `iam:CreateUser`, `iam:AddUserToGroup`
- `iam:CreateAccessKey`
- for rolling back a failed run: `iam:ListAccessKeys`, `iam:DeleteAccessKey`, `iam:RemoveUserFromGroup`, `iam:DeleteUser`, `iam:GetAccessKeyLastUsed`, `iam:ListGroupsForUser`

## Multi-User Strategy

AWS allows only **2 access keys per IAM user**, which is too few for team sharing. Instead, this skill creates:
- An **IAM group** (`claude-agents-<repo>-<suffix>`) with the shared policies attached
- A **separate IAM user per team member** (`claude-agent-<repo>-<suffix>-<email>`) added to that group

Both names include the repository, because IAM group and user names must be unique within an AWS account: two repositories bootstrapped in one account must neither collide nor share a group (which would mix their policies). See "IAM Names" below.

Each team member gets their own IAM user and access key, but all users inherit the same permissions from the group. The `.cloud-config.json` `service_account` field stores the group name.

## CLI Installation

The Claude Code on the Web sandbox may not have `aws` pre-installed. Use this script to install it:

```bash
if ! command -v aws &> /dev/null; then
  for dir in /home/user/bin /usr/local/bin /home/user/aws-cli/v2/current/bin; do
    if [ -x "$dir/aws" ]; then export PATH="$dir:$PATH"; break; fi
  done
fi
if ! command -v aws &> /dev/null; then
  if curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip 2>/dev/null && \
     unzip -q /tmp/awscliv2.zip -d /tmp && \
     /tmp/aws/install --install-dir /home/user/aws-cli --bin-dir /home/user/bin; then
    export PATH="/home/user/bin:$PATH"
  else
    echo "WARNING: AWS CLI install failed."
  fi
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi
```

### SessionStart Hook

After setup completes, create a SessionStart hook that installs the CLI **and** authenticates automatically. Create `.claude/hooks/cloud-auth.sh`:

```bash
#!/bin/bash
set -e

# Claude Code on the Web only: each session is its own container. Locally this
# would replace the developer's own AWS identity for the session with the
# repo's, so local users keep their own credentials.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then exit 0; fi
# Hooks run in the session's current directory, which may be a subdirectory
cd "${CLAUDE_PROJECT_DIR:-.}"

# --- Auto-authenticate if credentials exist ---
CONFIG=".cloud-config.json"
if [ ! -f "$CONFIG" ]; then exit 0; fi

PROVIDER=$(jq -r .provider "$CONFIG" 2>/dev/null) || exit 0
if [ "$PROVIDER" != "aws" ]; then exit 0; fi

USER_EMAIL=$(git config user.email 2>/dev/null || true)
ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
if [ -z "$USER_EMAIL" ] || [ ! -f "$ENC_FILE" ]; then exit 0; fi

KEY="${AWS_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}"
if [ -z "$KEY" ]; then exit 0; fi

# --- Per-file credential age, as in the Authenticate workflow ---
COMMIT_TS=$(git log --follow --diff-filter=AM -1 --format=%ct -- "$ENC_FILE" 2>/dev/null || true)
if [ -z "$COMMIT_TS" ]; then
  COMMIT_TS=$(date -d "$(jq -r '.created_at // empty' "$CONFIG")" +%s 2>/dev/null || true)
fi
if [ -n "$COMMIT_TS" ] && [ "$(( ( $(date +%s) - COMMIT_TS ) / 86400 ))" -gt 180 ]; then
  echo "NOTE: AWS credentials in $ENC_FILE are over 180 days old — consider rotating (see Credential Rotation)."
fi

# --- Install aws CLI if missing ---
if ! command -v aws &> /dev/null; then
  for dir in /home/user/bin /usr/local/bin /home/user/aws-cli/v2/current/bin; do
    if [ -x "$dir/aws" ]; then export PATH="$dir:$PATH"; break; fi
  done
fi
if ! command -v aws &> /dev/null; then
  if curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip 2>/dev/null && \
     unzip -q /tmp/awscliv2.zip -d /tmp && \
     /tmp/aws/install --install-dir /home/user/aws-cli --bin-dir /home/user/bin; then
    export PATH="/home/user/bin:$PATH"
  else
    echo "WARNING: AWS CLI install failed — skipping AWS auth."
    rm -rf /tmp/awscliv2.zip /tmp/aws
    exit 0
  fi
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

# --- Decrypt credentials (restrictive permissions + guaranteed cleanup) ---
trap 'rm -f /tmp/credentials.json' EXIT
if ! (umask 077 && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass stdin -in "$ENC_FILE" -out /tmp/credentials.json 2>/dev/null); then
  echo "WARNING: Failed to decrypt credentials — check AWS_CREDENTIALS_KEY or .enc file integrity."
  exit 0
fi

export AWS_ACCESS_KEY_ID=$(jq -r .access_key_id /tmp/credentials.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r .secret_access_key /tmp/credentials.json)
export AWS_DEFAULT_REGION=$(jq -r '.region // empty' /tmp/credentials.json)
# These are long-lived IAM-user keys: a session token left over from an earlier
# STS login would be sent with them and break every request. Clear it (and any
# profile selection) here and for the rest of the session below.
unset AWS_SESSION_TOKEN AWS_PROFILE

# Persist env vars for the session via CLAUDE_ENV_FILE. Persist the aws CLI
# bin dir too: if it was just installed under /home/user/bin, later session
# shells would otherwise have valid AWS_* vars but still hit "aws: command
# not found".
if [ -n "$CLAUDE_ENV_FILE" ]; then
  echo "export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'" >> "$CLAUDE_ENV_FILE"
  echo "export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'" >> "$CLAUDE_ENV_FILE"
  echo "export AWS_DEFAULT_REGION='$AWS_DEFAULT_REGION'" >> "$CLAUDE_ENV_FILE"
  echo "unset AWS_SESSION_TOKEN AWS_PROFILE" >> "$CLAUDE_ENV_FILE"
  AWS_BIN="$(dirname "$(command -v aws)")"
  grep -qxF "export PATH=\"$AWS_BIN:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "export PATH=\"$AWS_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

echo "AWS credentials activated for $USER_EMAIL"
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

**Note:** AWS credentials are environment variables, so the hook uses `$CLAUDE_ENV_FILE` to persist them for the entire session.

## Bootstrap Token Command

Tell the user to run locally:

```bash
aws sts get-session-token --duration-seconds 3600 \
  --serial-number arn:aws:iam::ACCOUNT_ID:mfa/MFA_DEVICE_NAME \
  --token-code 123456
```

Ask the user for their MFA device ARN (`aws iam list-mfa-devices`) and a current code. The MFA flags are required: credentials from `GetSessionToken` [cannot call IAM APIs unless MFA information is included](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetSessionToken.html), and setup immediately calls `iam:CreateGroup`, `iam:CreateUser`, and `iam:CreateAccessKey`.

This returns `AccessKeyId`, `SecretAccessKey`, and `SessionToken`, valid for 1 hour.

Alternatively, if the user has the AWS CLI configured, they can provide their temporary credentials directly:

```bash
# Simpler: just provide the existing credentials context
aws sts get-caller-identity   # to verify they're logged in
```

Then ask them to provide the output of:
```bash
# Emits the credentials the CLI actually resolved (environment, profile, assumed
# role, or IAM Identity Center), not just the AWS_* environment variables
aws configure export-credentials --format process
```

This returns `AccessKeyId`, `SecretAccessKey`, and `SessionToken` as JSON (AWS CLI v2). The IAM calls below still need credentials that permit IAM: session-token credentials need MFA, as above.

## API Approach

Use the AWS CLI (`aws`) if available in the environment. Otherwise, use signed API calls with the temporary credentials.

## IAM Names

First-Time Setup derives the group name and the user-name prefix from the repository name plus a random suffix (two repos with the same directory name in one account must not collide) and records them in `.cloud-config.json`: `service_account` holds the group, `iam_user_prefix` the user prefix. Every later workflow reads them back, so all members of one repo share one group and no two repos collide. Configs written before 1.5.0 have no `iam_user_prefix`; for them the snippets fall back to the old names (`claude-agents`, `claude-agent-<email>`), so existing users keep working. The user name is the prefix plus the email: IAM user names allow `.` and `@`, so a plain email is used unchanged, and an email with any other character, or a name over IAM's 64-character limit, gets a hash of the email as suffix, so distinct emails never map to one user. (The pre-1.5.0 names replaced `.` and `@` with `-`; that rule is kept only for the old `claude-agent` prefix.)

## First-Time Setup: Create Group and First User

```bash
# Export bootstrap credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
# The account ID gathered in First-Time Setup Step 2
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?set AWS_ACCOUNT_ID to the account ID gathered in Step 2}"

# Stop before any IAM change unless these credentials belong to the approved
# account: otherwise every resource below would land in the wrong account
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "ERROR: could not identify the bootstrap credentials' account; nothing created."; exit 1; }
[ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
  || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not $AWS_ACCOUNT_ID; nothing created."; exit 1; }

# Repo-scoped IAM names (see "IAM Names" above)
aws_cfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"aws\") | .$1) else (select(.provider==\"aws\") | .$1) end) // empty" .cloud-config.json 2>/dev/null; }
iam_user_name() {   # $1 = email, $2 = user prefix; result is at most 64 characters
  local h n
  h=$(printf '%s' "$1" | sha256sum | cut -c1-8)
  if [ "$2" = "claude-agent" ]; then
    # Pre-1.5.0 name, kept so existing users still resolve to their user
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,_-]/-/g')"
  else
    # IAM allows . and @, so a plain email is kept as is; any other character
    # is replaced and a hash of the email added, so distinct emails never
    # share a name
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,.@_-]/-/g')"
    [ "$n" = "$2-$1" ] || n="${n:0:55}-$h"
  fi
  [ ${#n} -le 64 ] || n="${n:0:55}-$h"
  printf '%s' "$n"
}

USER_EMAIL=$(git config user.email)
# Repo name plus a random suffix, so repos sharing a directory name in one
# account get distinct names. Keep values already set (a rerun, or names the
# user chose) and print them: later snippets of this setup need the same names
# until .cloud-config.json records them.
if [ -z "$GROUP_NAME" ] || [ -z "$USER_PREFIX" ]; then
  REPO_SLUG=$(basename "$(git rev-parse --show-toplevel)" | sed 's/[^A-Za-z0-9+=,_-]/-/g' | cut -c1-16)
  SUFFIX=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  GROUP_NAME="${GROUP_NAME:-claude-agents-${REPO_SLUG}-${SUFFIX}}"
  USER_PREFIX="${USER_PREFIX:-claude-agent-${REPO_SLUG}-${SUFFIX}}"
fi
echo "IAM names for this setup: GROUP_NAME=$GROUP_NAME USER_PREFIX=$USER_PREFIX (keep them until setup finishes)"
IAM_USER=$(iam_user_name "$USER_EMAIL" "$USER_PREFIX")

# Undo whatever this block created, so a failed run leaves nothing that would
# block a retry at the collision checks below.
CREATED_USER=""
rollback_aws_setup() {
  if [ -n "$CREATED_USER" ]; then
    for k in $(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
      aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k"
    done
    aws iam remove-user-from-group --group-name "$GROUP_NAME" --user-name "$IAM_USER" 2>/dev/null
    aws iam delete-user --user-name "$IAM_USER"
  fi
  # A group cannot be deleted while policies are attached: detach managed
  # policies and delete inline ones first (Grant Roles may already have run)
  for arn in $(aws iam list-attached-group-policies --group-name "$GROUP_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-group-policy --group-name "$GROUP_NAME" --policy-arn "$arn"
  done
  for pol in $(aws iam list-group-policies --group-name "$GROUP_NAME" --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-group-policy --group-name "$GROUP_NAME" --policy-name "$pol"
  done
  aws iam delete-group --group-name "$GROUP_NAME"
  rm -f credentials.json
}

# Create this repo's group; an existing group of that name belongs to another
# setup, so stop rather than share it
if ! aws iam create-group --group-name "$GROUP_NAME"; then
  echo "ERROR: could not create IAM group $GROUP_NAME (it may already exist); choose another name with the user."
  exit 1
fi

# Create the user and add to group; on any failure, roll back and stop
if ! aws iam create-user --user-name "$IAM_USER"; then
  echo "ERROR: could not create IAM user $IAM_USER (it may already exist); rolling back."
  rollback_aws_setup; exit 1
fi
CREATED_USER=1
aws iam add-user-to-group --group-name "$GROUP_NAME" --user-name "$IAM_USER" \
  || { echo "ERROR: add-user-to-group failed; rolling back."; rollback_aws_setup; exit 1; }

# Create access key
(umask 077 && aws iam create-access-key --user-name "$IAM_USER" > credentials.json) \
  || { echo "ERROR: create-access-key failed; rolling back."; rollback_aws_setup; exit 1; }
```

Reformat `credentials.json` to a clean structure before encrypting:

```bash
# umask 077: the reformatted file holds the secret key too, and mv keeps its mode
(umask 077 && jq --arg region "$AWS_REGION" '{
  access_key_id: .AccessKey.AccessKeyId,
  secret_access_key: .AccessKey.SecretAccessKey,
  region: $region
}' credentials.json > credentials_clean.json) && mv credentials_clean.json credentials.json
```

**Important:** Ask the user which AWS region to use and set `AWS_REGION` before running the above command (e.g., `AWS_REGION="us-east-1"`). The chosen region is persisted in the encrypted credentials and in `.cloud-config.json`.

If a later setup step fails (attaching a policy, encrypting, committing), undo the same resources before retrying: run `rollback_aws_setup` (define it as above, with `CREATED_USER=1`, `GROUP_NAME` and `IAM_USER` set), which deletes the user's access keys, removes the user from the group, deletes the user, detaches or deletes the group's policies, and deletes the group.

**For `.cloud-config.json`:** set `service_account` to `$GROUP_NAME` (the group) and add `"iam_user_prefix": "$USER_PREFIX"`, so later workflows derive the same names.

## Add Team Member: Create New User in Existing Group

```bash
# Repo-scoped IAM names (see "IAM Names" above)
aws_cfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"aws\") | .$1) else (select(.provider==\"aws\") | .$1) end) // empty" .cloud-config.json 2>/dev/null; }
iam_user_name() {   # $1 = email, $2 = user prefix; result is at most 64 characters
  local h n
  h=$(printf '%s' "$1" | sha256sum | cut -c1-8)
  if [ "$2" = "claude-agent" ]; then
    # Pre-1.5.0 name, kept so existing users still resolve to their user
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,_-]/-/g')"
  else
    # IAM allows . and @, so a plain email is kept as is; any other character
    # is replaced and a hash of the email added, so distinct emails never
    # share a name
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,.@_-]/-/g')"
    [ "$n" = "$2-$1" ] || n="${n:0:55}-$h"
  fi
  [ ${#n} -le 64 ] || n="${n:0:55}-$h"
  printf '%s' "$n"
}

USER_EMAIL=$(git config user.email)
# The group and user prefix this repo recorded at setup (provider-aware), not
# hard-coded names, or the new user won't inherit the repo's permissions.
GROUP_NAME=$(aws_cfg service_account); GROUP_NAME="${GROUP_NAME:-claude-agents}"
USER_PREFIX=$(aws_cfg iam_user_prefix); USER_PREFIX="${USER_PREFIX:-claude-agent}"
IAM_USER=$(iam_user_name "$USER_EMAIL" "$USER_PREFIX")
# The account this repo is configured for
AWS_ACCOUNT_ID=$(aws_cfg project_id)
[ -n "$AWS_ACCOUNT_ID" ] || { echo "ERROR: no AWS account (project_id) in .cloud-config.json."; exit 1; }

# Stop before any IAM change unless these credentials belong to the approved
# account: otherwise every resource below would land in the wrong account
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "ERROR: could not identify the bootstrap credentials' account; nothing created."; exit 1; }
[ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
  || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not $AWS_ACCOUNT_ID; nothing created."; exit 1; }

# Undo the user this block created (its keys, membership, then the user), so a
# failed run leaves nothing that blocks a retry at create-user. Never touches
# the shared group.
rollback_member() {
  for k in $(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k"
  done
  aws iam remove-user-from-group --group-name "$GROUP_NAME" --user-name "$IAM_USER" 2>/dev/null
  aws iam delete-user --user-name "$IAM_USER"
  rm -f credentials.json
}

# Create user and add to the existing group. Stop unless create-user succeeds:
# EntityAlreadyExists (409) means a user of this name already exists, and
# continuing would hand this member that user's identity. Nothing was created
# then, so there is nothing to roll back.
if ! aws iam create-user --user-name "$IAM_USER"; then
  echo "ERROR: could not create IAM user $IAM_USER (it may already exist); stop and resolve with the user."
  exit 1
fi
aws iam add-user-to-group --group-name "$GROUP_NAME" --user-name "$IAM_USER" \
  || { echo "ERROR: add-user-to-group failed; rolling back."; rollback_member; exit 1; }

# Create access key
(umask 077 && aws iam create-access-key --user-name "$IAM_USER" > credentials.json) \
  || { echo "ERROR: create-access-key failed; rolling back."; rollback_member; exit 1; }

# Reformat — read region from existing config. In multi-provider mode the
# region lives inside the matching providers[] entry, not at the top level.
AWS_REGION=$(jq -r '(if .providers then (.providers[] | select(.provider=="aws") | .region) else (select(.provider=="aws") | .region) end) // "us-east-1"' .cloud-config.json 2>/dev/null)
# umask 077: the reformatted file holds the secret key too, and mv keeps its mode
(umask 077 && jq --arg region "$AWS_REGION" '{
  access_key_id: .AccessKey.AccessKeyId,
  secret_access_key: .AccessKey.SecretAccessKey,
  region: $region
}' credentials.json > credentials_clean.json) && mv credentials_clean.json credentials.json
```

If a later step fails (encrypting, committing), roll the member back before retrying. This snippet stands alone, so it works from a fresh shell:

```bash
# Repo-scoped IAM names (see "IAM Names" above): define aws_cfg and
# iam_user_name as in the snippet above first
GROUP_NAME=$(aws_cfg service_account); GROUP_NAME="${GROUP_NAME:-claude-agents}"
USER_PREFIX=$(aws_cfg iam_user_prefix); USER_PREFIX="${USER_PREFIX:-claude-agent}"
IAM_USER=$(iam_user_name "$(git config user.email)" "$USER_PREFIX")
for k in $(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k"
done
aws iam remove-user-from-group --group-name "$GROUP_NAME" --user-name "$IAM_USER"
aws iam delete-user --user-name "$IAM_USER" && rm -f credentials.json
```

## Grant Roles (Attach Policies to Group)

Policies are attached to the **group**, not individual users. This way all team members share the same permissions. Each snippet below resolves the group itself, because it may run in a fresh shell. During first-time setup `.cloud-config.json` does not exist yet, so set `GROUP_NAME` to the name First-Time Setup printed. Run this first in the same snippet:

```bash
aws_cfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"aws\") | .$1) else (select(.provider==\"aws\") | .$1) end) // empty" .cloud-config.json 2>/dev/null; }
# The group First-Time Setup printed, else the configured one
GROUP_NAME="${GROUP_NAME:-$(aws_cfg service_account)}"
[ -n "$GROUP_NAME" ] || { echo "ERROR: set GROUP_NAME to the group First-Time Setup created."; exit 1; }
```

For AWS managed policies:

```bash
aws iam attach-group-policy \
  --group-name "$GROUP_NAME" \
  --policy-arn arn:aws:iam::aws:policy/POLICY_NAME
```

For inline policies (more granular):

```bash
aws iam put-group-policy \
  --group-name "$GROUP_NAME" \
  --policy-name descriptive-name \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }]
  }'
```

Prefer inline policies scoped to specific resources over broad managed policies.

## Activate (Subsequent Sessions)

After decrypting credentials to `/tmp/credentials.json`:

```bash
# Stored keys are long-lived IAM-user keys: a leftover session token or profile
# (from the bootstrap, an assumed role) would pair with them and fail, so clear
# both here and for the rest of the session
unset AWS_SESSION_TOKEN AWS_PROFILE
if [ -n "$CLAUDE_ENV_FILE" ]; then
  grep -qxF "unset AWS_SESSION_TOKEN AWS_PROFILE" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "unset AWS_SESSION_TOKEN AWS_PROFILE" >> "$CLAUDE_ENV_FILE"
fi
export AWS_ACCESS_KEY_ID=$(jq -r .access_key_id /tmp/credentials.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r .secret_access_key /tmp/credentials.json)
export AWS_DEFAULT_REGION=$(jq -r .region /tmp/credentials.json)
rm -f /tmp/credentials.json

# Persist for the rest of the session, not just this shell. SessionStart and
# one-off snippets run in short-lived subprocesses, so later AWS CLI commands
# in new shells would otherwise lose these exports. $CLAUDE_ENV_FILE is the
# harness mechanism for exporting env to the whole session.
if [ -n "$CLAUDE_ENV_FILE" ]; then
  {
    echo "export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'"
    echo "export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'"
    echo "export AWS_DEFAULT_REGION='$AWS_DEFAULT_REGION'"
  } >> "$CLAUDE_ENV_FILE"
fi

# Verify
aws sts get-caller-identity
```

**Note:** Unlike GCP, AWS credentials are exported as environment variables, not activated via a CLI command. Persisting them to `$CLAUDE_ENV_FILE` keeps them available across the session's shells (the SessionStart hook does this too); otherwise they only live for the current shell.

## Verify (Smoke Test)

After activating credentials, run this lightweight check to confirm they work:

```bash
aws sts get-caller-identity
```

If this fails, the credentials may be expired or revoked. Re-run the **Authenticate** flow or ask the user to check the IAM user.

## User Management

List users in the group:

```bash
aws_cfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"aws\") | .$1) else (select(.provider==\"aws\") | .$1) end) // empty" .cloud-config.json 2>/dev/null; }
GROUP_NAME=$(aws_cfg service_account); GROUP_NAME="${GROUP_NAME:-claude-agents}"
aws iam get-group --group-name "$GROUP_NAME"
```

Remove a team member (if they leave):

```bash
# Repo-scoped IAM names (see "IAM Names" above)
aws_cfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"aws\") | .$1) else (select(.provider==\"aws\") | .$1) end) // empty" .cloud-config.json 2>/dev/null; }
iam_user_name() {   # $1 = email, $2 = user prefix; result is at most 64 characters
  local h n
  h=$(printf '%s' "$1" | sha256sum | cut -c1-8)
  if [ "$2" = "claude-agent" ]; then
    # Pre-1.5.0 name, kept so existing users still resolve to their user
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,_-]/-/g')"
  else
    # IAM allows . and @, so a plain email is kept as is; any other character
    # is replaced and a hash of the email added, so distinct emails never
    # share a name
    n="$2-$(printf '%s' "$1" | sed 's/[^A-Za-z0-9+=,.@_-]/-/g')"
    [ "$n" = "$2-$1" ] || n="${n:0:55}-$h"
  fi
  [ ${#n} -le 64 ] || n="${n:0:55}-$h"
  printf '%s' "$n"
}
GROUP_NAME=$(aws_cfg service_account); GROUP_NAME="${GROUP_NAME:-claude-agents}"
USER_PREFIX=$(aws_cfg iam_user_prefix); USER_PREFIX="${USER_PREFIX:-claude-agent}"
MEMBER_EMAIL="departed-user@example.com"
IAM_USER=$(iam_user_name "$MEMBER_EMAIL" "$USER_PREFIX")

# Delete nothing unless the bootstrap credentials belong to this repo's
# account: a same-named user in another account is not this member
AWS_ACCOUNT_ID=$(aws_cfg project_id)
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "ERROR: could not identify the bootstrap credentials' account; nothing deleted."; exit 1; }
[ -n "$AWS_ACCOUNT_ID" ] && [ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
  || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not ${AWS_ACCOUNT_ID:-the configured one}; nothing deleted."; exit 1; }

# Every step must succeed before the member's credential file goes: a failed
# deletion leaves a live user or key, and the file is the repo's record of it.
KEYS=$(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text) \
  || { echo "ERROR: could not list $IAM_USER's access keys; nothing deleted."; exit 1; }
for KEY_ID in $KEYS; do
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$KEY_ID" \
    || { echo "ERROR: could not delete key $KEY_ID; the credential file stays. Retry."; exit 1; }
done
# Remove from the configured group, then delete: delete-user fails while any
# group membership remains.
aws iam remove-user-from-group --group-name "$GROUP_NAME" --user-name "$IAM_USER" \
  && aws iam delete-user --user-name "$IAM_USER" \
  || { echo "ERROR: could not remove or delete $IAM_USER; the credential file stays. Retry."; exit 1; }
# All gone: now remove the member's credential file and any pending entries
git rm -q --ignore-unmatch ".cloud-credentials.aws.${MEMBER_EMAIL}.enc" ".cloud-credentials.${MEMBER_EMAIL}.enc"
# (deleting the user removed every key it had, including any recorded as unrevoked)
jq --arg e "$MEMBER_EMAIL" '
  def clr: del(.revoke_pending[$e]) | del(.rotating[$e]);
  .unrevoked = [(.unrevoked // [])[] | select(.provider != "aws" or .member != $e)]
  | if .unrevoked == [] then del(.unrevoked) else . end
  | if .providers then .providers |= map(if .provider == "aws" then clr else . end) else clr end' \
  .cloud-config.json > .cloud-config.json.tmp && mv .cloud-config.json.tmp .cloud-config.json
```

Commit the removed credential file and `.cloud-config.json` together.

## Common Policies Reference

| Need | Managed Policy |
|------|---------------|
| Deploy Lambda | `AWSLambda_FullAccess` (or scoped inline) |
| Manage S3 | `AmazonS3FullAccess` (prefer inline with bucket scope) |
| Manage DynamoDB | `AmazonDynamoDBFullAccess` |
| Deploy via CloudFormation | `AWSCloudFormationFullAccess` |
| Manage SQS | `AmazonSQSFullAccess` |
| Manage SNS | `AmazonSNSFullAccess` |
| Read CloudWatch logs | `CloudWatchLogsReadOnlyAccess` |
| Manage API Gateway | `AmazonAPIGatewayAdministrator` |
| Manage ECS/Fargate | `AmazonECS_FullAccess` |
| Manage Secrets Manager | `SecretsManagerReadWrite` |

**Prefer inline policies scoped to specific resources over these broad managed policies.**
