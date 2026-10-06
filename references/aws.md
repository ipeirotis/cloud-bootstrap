# AWS Reference

## User Prerequisites (First-Time Setup)

The user's AWS account needs **IAM full access** or at minimum:
- `iam:CreateGroup`, `iam:CreateUser`, `iam:AddUserToGroup`
- `iam:GetGroup`, `iam:GetUser` (the collision checks before creating, and confirming a failed create left nothing)
- `iam:CreateAccessKey`
- `iam:AttachGroupPolicy` / `iam:PutGroupPolicy`
- for rolling back a failed setup: `iam:ListAccessKeys`, `iam:DeleteAccessKey`, `iam:RemoveUserFromGroup`, `iam:DeleteUser`, `iam:ListGroupsForUser`, `iam:ListAttachedGroupPolicies`, `iam:ListGroupPolicies`, `iam:DetachGroupPolicy`, `iam:DeleteGroupPolicy`, `iam:DeleteGroup`
- for credential rotation (which uses the same bootstrap credentials) and its cleanup: `iam:GetAccessKeyLastUsed`, `iam:GetUser`, plus `iam:CreateAccessKey`, `iam:ListAccessKeys`, `iam:DeleteAccessKey` above

## Team Member Prerequisites (Adding to Existing Setup)

The user's AWS account needs:
- `iam:CreateUser`, `iam:AddUserToGroup`
- `iam:GetUser` (confirming a failed `create-user` left nothing)
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

# Undo an earlier activation in this container (the exported keys persisted
# for the session) whenever this run exits without renewing it: a removed
# passphrase or a broken file must disable repository auth
clear_prior_aws() {
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
    sed -i '/^export AWS_ACCESS_KEY_ID=/d; /^export AWS_SECRET_ACCESS_KEY=/d; /^export AWS_DEFAULT_REGION=/d' "$CLAUDE_ENV_FILE"
    # A profile or session token left selected would let later commands
    # authenticate as something else instead of failing
    echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_PROFILE AWS_SESSION_TOKEN" >> "$CLAUDE_ENV_FILE"
  fi
}
trap '[ "${AWS_ACTIVATED:-}" = 1 ] || clear_prior_aws; rm -f /tmp/credentials.json' EXIT

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
# (the EXIT trap set above also removes /tmp/credentials.json)
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
# Use the keys only as this member's user in this repo's account: a stale or
# copied file could hold valid keys for another account or another user
ACCOUNT=$(jq -r '.project_id // empty' "$CONFIG" 2>/dev/null)
PREFIX=$(jq -r '.iam_user_prefix // empty' "$CONFIG" 2>/dev/null); PREFIX="${PREFIX:-claude-agent}"
WANT_USER=$(expected_iam_user "$USER_EMAIL" "$PREFIX")
read -r CALLER CALLER_ARN <<< "$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT" ] || [ "${CALLER:-}" != "$ACCOUNT" ] || [ "${CALLER_ARN#arn:*:}" != "iam::$ACCOUNT:user/$WANT_USER" ]; then
  echo "WARNING: $ENC_FILE is for ${CALLER_ARN:-an unknown identity (lookup failed)}, not user $WANT_USER in account ${ACCOUNT:-(not configured)}; not activating it."
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  exit 0
fi

# Persist env vars for the session via CLAUDE_ENV_FILE. Persist the aws CLI
# bin dir too: if it was just installed under /home/user/bin, later session
# shells would otherwise have valid AWS_* vars but still hit "aws: command
# not found".
if [ -n "$CLAUDE_ENV_FILE" ]; then
  # Drop an unset an earlier failed run left, so the exports below take effect
  sed -i '/^unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_PROFILE AWS_SESSION_TOKEN$/d' "$CLAUDE_ENV_FILE" 2>/dev/null || true
  echo "export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'" >> "$CLAUDE_ENV_FILE"
  echo "export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'" >> "$CLAUDE_ENV_FILE"
  echo "export AWS_DEFAULT_REGION='$AWS_DEFAULT_REGION'" >> "$CLAUDE_ENV_FILE"
  echo "unset AWS_SESSION_TOKEN AWS_PROFILE" >> "$CLAUDE_ENV_FILE"
  AWS_BIN="$(dirname "$(command -v aws)")"
  grep -qxF "export PATH=\"$AWS_BIN:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
    echo "export PATH=\"$AWS_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

AWS_ACTIVATED=1
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
# MFA_DEVICE_ARN exactly as `aws iam list-mfa-devices --query 'MFADevices[].SerialNumber'`
# prints it (its partition is arn:aws, arn:aws-cn or arn:aws-us-gov)
aws sts get-session-token --duration-seconds 3600 \
  --serial-number "MFA_DEVICE_ARN" \
  --token-code 123456
```

Ask the user for their MFA device ARN, copied whole from `aws iam list-mfa-devices` (never rebuilt from the account ID, which would assume the commercial `aws` partition), and a current code. The MFA flags are required: credentials from `GetSessionToken` [cannot call IAM APIs unless MFA information is included](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetSessionToken.html), and setup immediately calls `iam:CreateGroup`, `iam:CreateUser`, and `iam:CreateAccessKey`.

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
[ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
# Repo name plus a random suffix, so repos sharing a directory name in one
# account get distinct names. Keep values already set (a rerun, or names the
# user chose) and print them: later snippets of this setup need the same names
# until .cloud-config.json records them.
# A generated group name carries a random suffix no other setup can share; a
# chosen one (or a rerun's) can collide with a concurrent setup
GROUP_GENERATED=""; [ -n "$GROUP_NAME" ] || GROUP_GENERATED=1
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

# Record the names before creating anything (not secret), so "Rollback a
# Failed Setup" can find them from any shell if this run stops part-way
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
pending() {   # written whole to a temp file, then renamed: never left half-written
  jq -n --arg a "$AWS_ACCOUNT_ID" --arg g "$GROUP_NAME" --arg p "$USER_PREFIX" --arg u "${1:-}" \
    '{provider: "aws", account: $a, group: $g, user_prefix: $p} + (if $u != "" then {iam_user: $u} else {} end)' \
    > .cloud-setup-pending.json.tmp && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json; }
pending || { echo "ERROR: could not write .cloud-setup-pending.json; nothing created."; exit 1; }

# Create this repo's group; an existing group of that name belongs to another
# setup, so stop rather than share it
# The name must be free first, so a group found after a failed call is ours
if OUT=$(aws iam get-group --group-name "$GROUP_NAME" 2>&1) || ! printf '%s' "$OUT" | grep -q NoSuchEntity; then
  rm -f .cloud-setup-pending.json
  echo "ERROR: IAM group $GROUP_NAME already exists (or the lookup failed); choose another name with the user."
  exit 1
fi
if ! aws iam create-group --group-name "$GROUP_NAME"; then
  # A lost response can hide a group that was created: keep the record unless
  # the group is confirmed absent
  if OUT=$(aws iam get-group --group-name "$GROUP_NAME" 2>&1) || ! printf '%s' "$OUT" | grep -q NoSuchEntity; then
    if [ -z "$GROUP_GENERATED" ]; then
      # A chosen name: the group may be a concurrent setup's that won the
      # race, so the rollback must not touch it unless a person confirms
      if jq '. + {ambiguous_group: true}' .cloud-setup-pending.json > .cloud-setup-pending.json.tmp \
        && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json; then
        echo "ERROR: create-group failed and $GROUP_NAME exists, created by this run or by another setup using the same name."
        echo "Check with the user before running Rollback a Failed Setup with CONFIRM_GROUP=1 (or delete the record if it is not this run's)."
      else
        # Unmarked, the record would let a rollback delete a group that may be
        # another setup's. It names nothing else yet, so drop it and leave the
        # group to a person
        rm -f .cloud-setup-pending.json.tmp .cloud-setup-pending.json
        echo "ERROR: create-group failed, $GROUP_NAME exists, and the record could not be marked as unconfirmed, so it was removed."
        echo "Check with the user whether $GROUP_NAME is this run's; only then delete it by hand (aws iam delete-group --group-name $GROUP_NAME)."
        [ ! -e .cloud-setup-pending.json ] || echo "ERROR: .cloud-setup-pending.json could not be removed either; delete it by hand before any rollback."
      fi
    else
      echo "ERROR: create-group failed and $GROUP_NAME may exist; run Rollback a Failed Setup (the record is kept)."
    fi
  else
    rm -f .cloud-setup-pending.json
    echo "ERROR: could not create IAM group $GROUP_NAME; nothing was created."
  fi
  exit 1
fi

# Record the user before creating it, so an interruption right after
# create-user is still recovered. Only a name confirmed absent is recorded,
# so a pre-existing user of that name is never one the rollback deletes.
if OUT=$(aws iam get-user --user-name "$IAM_USER" 2>&1) || ! printf '%s' "$OUT" | grep -q NoSuchEntity; then
  echo "ERROR: IAM user $IAM_USER already exists (or the lookup failed); rolling back."
  rollback_aws_setup; exit 1
fi
pending "$IAM_USER" || { echo "ERROR: could not update .cloud-setup-pending.json; rolling back."; rollback_aws_setup; exit 1; }
# Create the user and add to group; on any failure, roll back and stop
if ! aws iam create-user --user-name "$IAM_USER"; then
  # A lost response can hide a user that was created (the name was free just
  # before): drop it from the record only when AWS confirms it is absent,
  # otherwise roll it back with the group and keep it recorded
  if OUT=$(aws iam get-user --user-name "$IAM_USER" 2>&1) || ! printf '%s' "$OUT" | grep -q NoSuchEntity; then
    CREATED_USER=1
  else
    pending ""
  fi
  echo "ERROR: could not create IAM user $IAM_USER; rolling back."
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

If a later setup step fails (attaching a policy, encrypting, committing), or the run was interrupted, undo the same resources before retrying with "Rollback a Failed Setup" below.

### Rollback a Failed Setup

Run it from any shell: it reads the names from `.cloud-setup-pending.json` (or `AWS_ACCOUNT_ID`, `GROUP_NAME`, `IAM_USER`), checks the account, and deletes the user's access keys, its group memberships and the user, then the group's policies and the group. For a record Add Team Member wrote (`member_only`), it deletes only that member's user and leaves the shared group. Anything already gone counts as done. The pending record is deleted only when everything is gone.

```bash
PENDING=.cloud-setup-pending.json
pend() { jq -r --arg k "$1" 'select(.provider == "aws") | .[$k] // empty' "$PENDING" 2>/dev/null; }
# With a record, its identity wins: a value left in the shell by another
# operation must match it or be unset (shell values are used only without one)
HAVE_REC=$(jq -r 'select(.provider == "aws") | "yes"' "$PENDING" 2>/dev/null)
pick() {   # $1 = variable, $2 = the record's value
  [ -n "$HAVE_REC" ] || return 0
  [ -z "${!1:-}" ] || [ "${!1}" = "$2" ] \
    || { echo "ERROR: $1 is ${!1}, but $PENDING names ${2:-none}; nothing changed. Unset $1."; exit 1; }
  printf -v "$1" '%s' "$2"
}
pick AWS_ACCOUNT_ID "$(pend account)"
pick IAM_USER "$(pend iam_user)"   # empty: the user was never created
# An ambiguous record (Add Team Member found the user after a failed
# create-user) may name a user another run created: delete it only when a
# person confirmed it is this run's
if [ "$(pend ambiguous_group)" = true ] && [ "${CONFIRM_GROUP:-}" != 1 ]; then
  echo "ERROR: $PENDING marks group $(pend group) as possibly another setup's; nothing deleted."
  echo "Confirm with the user it is this run's group, then re-run with CONFIRM_GROUP=1 (or delete $PENDING if it is not)."
  exit 1
fi
if [ "$(pend ambiguous)" = true ] && [ "${CONFIRM_USER:-}" != 1 ]; then
  echo "ERROR: $PENDING marks $IAM_USER as possibly created by another run; nothing deleted."
  echo "Confirm with the user it is this run's user, then re-run with CONFIRM_USER=1 (or delete $PENDING if it is not)."
  exit 1
fi
# An Add Team Member record (member_only) covers only the member's user: the
# shared group belongs to the whole team and is never deleted here
if [ "$(pend member_only)" = true ]; then GROUP_NAME=""; else pick GROUP_NAME "$(pend group)"; fi
[ -n "$AWS_ACCOUNT_ID" ] && { [ -n "$GROUP_NAME" ] || [ -n "$IAM_USER" ]; } \
  || { echo "ERROR: set AWS_ACCOUNT_ID and GROUP_NAME or IAM_USER (no AWS entry in $PENDING)."; exit 1; }
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "ERROR: could not identify the bootstrap credentials' account; nothing deleted."; exit 1; }
[ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
  || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not $AWS_ACCOUNT_ID; nothing deleted."; exit 1; }
RB_OK=1; DELETED_KEYS=""
gone() { printf '%s' "$1" | grep -q NoSuchEntity; }
if [ -n "$IAM_USER" ]; then
  if OUT=$(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>&1); then
    for k in $OUT; do
      if aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k"; then DELETED_KEYS="$DELETED_KEYS $k"; else RB_OK=0; fi
    done
    for g in $(aws iam list-groups-for-user --user-name "$IAM_USER" --query 'Groups[].GroupName' --output text); do
      aws iam remove-user-from-group --group-name "$g" --user-name "$IAM_USER" || RB_OK=0
    done
    aws iam delete-user --user-name "$IAM_USER" || RB_OK=0
  elif ! gone "$OUT"; then
    RB_OK=0; echo "WARNING: could not list $IAM_USER's keys: $OUT"
  fi
fi
if [ -z "$GROUP_NAME" ]; then
  :   # member-only rollback: the shared group stays
elif OUT=$(aws iam list-attached-group-policies --group-name "$GROUP_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>&1); then
  for arn in $OUT; do aws iam detach-group-policy --group-name "$GROUP_NAME" --policy-arn "$arn" || RB_OK=0; done
  for pol in $(aws iam list-group-policies --group-name "$GROUP_NAME" --query 'PolicyNames[]' --output text); do
    aws iam delete-group-policy --group-name "$GROUP_NAME" --policy-name "$pol" || RB_OK=0
  done
  aws iam delete-group --group-name "$GROUP_NAME" || RB_OK=0
elif ! gone "$OUT"; then
  RB_OK=0; echo "WARNING: could not inspect group $GROUP_NAME: $OUT"
fi
if [ "$RB_OK" = 1 ]; then
  # Drop the "unrevoked" entries this rollback resolved (a failed discard may
  # have recorded them), or every later phase check would report credentials
  # that no longer exist: the key IDs deleted above, and placeholders naming
  # this user (recorded only after the account check). Entries for another
  # account or an unknown owner stay: they may still be live elsewhere.
  if [ -n "$IAM_USER" ] && [ -f .cloud-config.json ]; then
    jq --arg u "$IAM_USER" --arg ks "$DELETED_KEYS" '
      ($ks | split(" ") | map(select(. != ""))) as $gone
      | .unrevoked = [(.unrevoked // [])[] | select(.provider != "aws"
          or ((.id | IN($gone[])) | not)
             and ((.id == "(user \($u))" or .id == "(all keys of \($u))" or .id == "(new key of \($u))") | not))]
      | if .unrevoked == [] then del(.unrevoked) else . end' .cloud-config.json > .cloud-config.json.tmp \
      && mv .cloud-config.json.tmp .cloud-config.json && echo "Commit .cloud-config.json if it changed."
  fi
  rm -f credentials.json credentials_clean.json "$PENDING"; echo "Rollback complete."
else
  echo "Rollback incomplete; $PENDING is kept. Re-run this block."; exit 1
fi
```

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
[ -n "$USER_EMAIL" ] || { echo "ERROR: git config user.email is not set; set it (it names your credential file), then retry."; exit 1; }
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
# The name must be free first: a user that already exists belongs to someone
# else (another member whose email maps to the same name, or an earlier
# setup), and recording it would let a later rollback delete it
if OUT=$(aws iam get-user --user-name "$IAM_USER" 2>&1) || ! printf '%s' "$OUT" | grep -q NoSuchEntity; then
  echo "ERROR: IAM user $IAM_USER already exists (or the lookup failed); nothing created. Resolve with the user."
  exit 1
fi
# Record the member's user before creating it (not secret; member_only: a
# rollback removes this user, never the shared group), so an interruption
# before credentials.json exists is still recovered from any shell
jq -n --arg a "$AWS_ACCOUNT_ID" --arg u "$IAM_USER" \
  '{provider: "aws", member_only: true, account: $a, iam_user: $u}' > .cloud-setup-pending.json.tmp \
  && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json \
  || { echo "ERROR: could not write .cloud-setup-pending.json; nothing created."; exit 1; }
# Create user and add to the existing group. Stop unless create-user succeeds:
# continuing would hand this member whatever user holds that name.
if ! aws iam create-user --user-name "$IAM_USER"; then
  # A user found now was created after the check above: by this run (a lost
  # response) or by an overlapping run for the same email. Ownership is
  # unknown, so mark the record ambiguous: the rollback then never deletes the
  # user unless a person confirms it is this run's
  if OUT=$(aws iam get-user --user-name "$IAM_USER" 2>&1); then
    if jq '. + {ambiguous: true}' .cloud-setup-pending.json > .cloud-setup-pending.json.tmp \
      && mv .cloud-setup-pending.json.tmp .cloud-setup-pending.json; then
      echo "ERROR: create-user failed but $IAM_USER now exists, created by this run or by another run for the same email."
      echo "Check with the user (and any teammate onboarding the same email) before running Rollback a Failed Setup with CONFIRM_USER=1."
    else
      # Unmarked, the record would let a rollback delete a user that may be an
      # overlapping run's. No key or group membership exists yet, so drop the
      # record and leave the user to a person
      rm -f .cloud-setup-pending.json.tmp .cloud-setup-pending.json
      echo "ERROR: create-user failed, $IAM_USER exists, and the record could not be marked as unconfirmed, so it was removed."
      echo "Check with the user (and any teammate onboarding the same email) whether $IAM_USER is this run's; only then delete it by hand (aws iam delete-user --user-name $IAM_USER)."
      [ ! -e .cloud-setup-pending.json ] || echo "ERROR: .cloud-setup-pending.json could not be removed either; delete it by hand before any rollback."
    fi
  elif printf '%s' "$OUT" | grep -q NoSuchEntity; then
    rm -f .cloud-setup-pending.json
    echo "ERROR: could not create IAM user $IAM_USER; nothing was created."
  else
    echo "ERROR: create-user failed and the user's state is unknown; the record is kept for Rollback a Failed Setup."
  fi
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
# Only in this repo's account: a same-named user elsewhere is not this member
AWS_ACCOUNT_ID=$(aws_cfg project_id)
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "ERROR: could not identify the bootstrap credentials' account; nothing deleted."; exit 1; }
[ -n "$AWS_ACCOUNT_ID" ] && [ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
  || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not ${AWS_ACCOUNT_ID:-the configured one}; nothing deleted."; exit 1; }
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
# This repo's group: the one the setup record names during first-time setup,
# else the configured one. A GROUP_NAME left in the shell by another setup
# must not redirect the policies, so a conflicting one stops the snippet
WANT_GROUP=$(jq -r 'select(.provider=="aws") | .group // empty' .cloud-setup-pending.json 2>/dev/null)
WANT_GROUP="${WANT_GROUP:-$(aws_cfg service_account)}"
if [ -n "$WANT_GROUP" ]; then
  [ -z "${GROUP_NAME:-}" ] || [ "$GROUP_NAME" = "$WANT_GROUP" ] \
    || { echo "ERROR: GROUP_NAME is $GROUP_NAME, but this repo's group is $WANT_GROUP; nothing changed. Unset GROUP_NAME."; exit 1; }
  GROUP_NAME="$WANT_GROUP"
fi
[ -n "${GROUP_NAME:-}" ] || { echo "ERROR: set GROUP_NAME to the group First-Time Setup created."; exit 1; }
# Change nothing unless these credentials are in this repo's account (from the
# config, or during setup from its record): group names are only unique per
# account, and the policy commands take no account
# The recorded account wins over an AWS_ACCOUNT_ID left in the shell: the
# policy commands take a bare group name and no account
WANT_ACCOUNT=$(jq -r 'select(.provider=="aws") | .account // empty' .cloud-setup-pending.json 2>/dev/null)
WANT_ACCOUNT="${WANT_ACCOUNT:-$(aws_cfg project_id)}"
if [ -n "$WANT_ACCOUNT" ]; then
  [ -z "${AWS_ACCOUNT_ID:-}" ] || [ "$AWS_ACCOUNT_ID" = "$WANT_ACCOUNT" ] \
    || { echo "ERROR: AWS_ACCOUNT_ID is $AWS_ACCOUNT_ID, but this repo's account is $WANT_ACCOUNT; nothing changed. Unset AWS_ACCOUNT_ID."; exit 1; }
  AWS_ACCOUNT_ID="$WANT_ACCOUNT"
fi
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "ERROR: could not identify the bootstrap credentials' account; nothing changed."; exit 1; }
[ -n "$AWS_ACCOUNT_ID" ] && [ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
  || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not ${AWS_ACCOUNT_ID:-the configured one}; nothing changed."; exit 1; }
```

For AWS managed policies:

```bash
# The partition (aws, aws-cn, aws-us-gov) of the account these credentials are in
PARTITION=$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)
aws iam attach-group-policy \
  --group-name "$GROUP_NAME" \
  --policy-arn "arn:$PARTITION:iam::aws:policy/POLICY_NAME"
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
      "Resource": "arn:PARTITION:s3:::BUCKET_NAME/*"
    }]
  }'
```

Replace `PARTITION` with the account's partition (`aws`, or `aws-cn` / `aws-us-gov`; see above). Prefer inline policies scoped to specific resources over broad managed policies.

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

# Persist nothing unless these keys are this member's user in this repo's
# account (a stale or copied file could hold another account's or user's keys)
aws_cfg() { jq -r "(if .providers then (.providers[] | select(.provider==\"aws\") | .$1) else (select(.provider==\"aws\") | .$1) end) // empty" .cloud-config.json 2>/dev/null; }
iam_user_name() {   # $1 = email, $2 = user prefix (see "IAM Names")
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
ACCOUNT=$(aws_cfg project_id); PREFIX=$(aws_cfg iam_user_prefix); PREFIX="${PREFIX:-claude-agent}"
WANT_USER=$(iam_user_name "$(git config user.email)" "$PREFIX")
read -r CALLER CALLER_ARN <<< "$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT" ] || [ "${CALLER:-}" != "$ACCOUNT" ] || [ "${CALLER_ARN#arn:*:}" != "iam::$ACCOUNT:user/$WANT_USER" ]; then
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  # Drop keys an earlier activation persisted too, or later shells restore them
  if [ -n "$CLAUDE_ENV_FILE" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
    sed -i '/^export AWS_ACCESS_KEY_ID=/d; /^export AWS_SECRET_ACCESS_KEY=/d; /^export AWS_DEFAULT_REGION=/d' "$CLAUDE_ENV_FILE"
    echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_PROFILE AWS_SESSION_TOKEN" >> "$CLAUDE_ENV_FILE"
  fi
  echo "ERROR: these keys are for ${CALLER_ARN:-an unknown identity}, not user $WANT_USER in account ${ACCOUNT:-(not configured)}; not activated."
  exit 1
fi

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

echo "Activated as $CALLER_ARN"
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
# Pre-1.5 names (prefix claude-agent) replace . and @, so distinct emails can
# share a user (alice.smith@ and alice-smith@). Before deleting anything,
# require this member's own credential file and refuse when another member's
# email maps to the same user, unless a person confirmed it (CONFIRM_USER=1)
if [ "$USER_PREFIX" = "claude-agent" ] && [ "${CONFIRM_USER:-}" != 1 ]; then
  # The naming mode comes from the config, not from the file name: an email
  # can itself begin with "aws." or "gcp."
  if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then PFX="aws."; else PFX=""; fi
  [ -f ".cloud-credentials.${PFX}${MEMBER_EMAIL}.enc" ] \
    || { echo "ERROR: no credential file for $MEMBER_EMAIL; check the address (or set CONFIRM_USER=1 once confirmed)."; exit 1; }
  for F in .cloud-credentials.${PFX}*.enc; do
    [ -e "$F" ] || continue
    E=${F#.cloud-credentials.$PFX}; E=${E%.enc}
    if [ "$E" != "$MEMBER_EMAIL" ] && [ "$(iam_user_name "$E" "$USER_PREFIX")" = "$IAM_USER" ]; then
      echo "ERROR: $E maps to the same IAM user $IAM_USER as $MEMBER_EMAIL; nothing deleted. Resolve with the user (CONFIRM_USER=1 to proceed)."
      exit 1
    fi
  done
fi

# Delete nothing unless the bootstrap credentials belong to this repo's
# account: a same-named user in another account is not this member
AWS_ACCOUNT_ID=$(aws_cfg project_id)
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "ERROR: could not identify the bootstrap credentials' account; nothing deleted."; exit 1; }
[ -n "$AWS_ACCOUNT_ID" ] && [ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
  || { echo "ERROR: bootstrap credentials belong to account $CALLER_ACCOUNT, not ${AWS_ACCOUNT_ID:-the configured one}; nothing deleted."; exit 1; }

# Every step must succeed before the member's credential file goes: a failed
# deletion leaves a live user or key, and the file is the repo's record of it.
# Each step works from the user's current state, so a retry after a partial
# run continues where it stopped; a user that no longer exists is done.
DELETED_KEYS=""
if KEYS=$(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>&1); then
  for KEY_ID in $KEYS; do
    aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$KEY_ID" \
      || { echo "ERROR: could not delete key $KEY_ID; the credential file stays. Retry."; exit 1; }
    DELETED_KEYS="$DELETED_KEYS $KEY_ID"
    # Clear its "unrevoked" entry right away: a retry after a later failure no
    # longer sees this key, so it could not prove it gone then. Stop if that
    # write fails, for the same reason
    if ! { jq --arg id "$KEY_ID" '.unrevoked = [(.unrevoked // [])[] | select(.provider != "aws" or .id != $id)]
      | if .unrevoked == [] then del(.unrevoked) else . end' .cloud-config.json > .cloud-config.json.tmp \
      && mv .cloud-config.json.tmp .cloud-config.json; }; then
      rm -f .cloud-config.json.tmp
      echo "ERROR: deleted key $KEY_ID but could not update .cloud-config.json; the credential file stays."
      echo "Fix the file, remove any \"unrevoked\" entry for $KEY_ID by hand (the key is gone), then retry."
      exit 1
    fi
  done
  # delete-user fails while any group membership remains: remove the ones the
  # user still has (none, if an earlier attempt already did)
  GROUPS_NOW=$(aws iam list-groups-for-user --user-name "$IAM_USER" --query 'Groups[].GroupName' --output text) \
    || { echo "ERROR: could not list $IAM_USER's groups; the credential file stays. Retry."; exit 1; }
  for g in $GROUPS_NOW; do
    aws iam remove-user-from-group --group-name "$g" --user-name "$IAM_USER" \
      || { echo "ERROR: could not remove $IAM_USER from $g; the credential file stays. Retry."; exit 1; }
  done
  aws iam delete-user --user-name "$IAM_USER" \
    || { echo "ERROR: could not delete $IAM_USER; the credential file stays. Retry."; exit 1; }
elif printf '%s' "$KEYS" | grep -q NoSuchEntity; then
  echo "$IAM_USER no longer exists."
else
  echo "ERROR: could not list $IAM_USER's access keys: $KEYS"; exit 1
fi
# All gone: now remove the member's credential file and any pending entries
git rm -q --ignore-unmatch ".cloud-credentials.aws.${MEMBER_EMAIL}.enc" ".cloud-credentials.${MEMBER_EMAIL}.enc"
# "unrevoked" entries go only when this run proved them gone: the key IDs it
# deleted, and placeholders naming this user. An entry recorded for another
# account or an unconfirmed owner stays: it may still be live elsewhere.
jq --arg e "$MEMBER_EMAIL" --arg u "$IAM_USER" --arg ks "$DELETED_KEYS" '
  def clr: del(.revoke_pending[$e]) | del(.rotating[$e]) | del(.revoked_early[$e]) | del(.rotated[$e]);
  ($ks | split(" ") | map(select(. != ""))) as $gone
  | .unrevoked = [(.unrevoked // [])[] | select(.provider != "aws"
      or ((.id | IN($gone[])) | not)
         and ((.id == "(user \($u))" or .id == "(all keys of \($u))" or .id == "(new key of \($u))") | not))]
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
