---
name: cloud-bootstrap
description: Bootstrap and manage cloud service account credentials (GCP, AWS, Azure) for a repo used in Claude Code on the Web. Use this skill whenever the user mentions GCP, Google Cloud, AWS, Amazon Web Services, Azure, service accounts, cloud credentials, IAM, or wants to set up cloud infrastructure for a project. Also trigger when you detect .cloud-credentials.*.enc or .cloud-config.json in the repo, or when a cloud API call fails with authentication or permission errors. This skill handles first-time setup, adding new team members, and subsequent session authentication. Even if the user just says "deploy to Lambda" or "set up a Cloud Run service" or "create an Azure Function", use this skill first to ensure cloud auth is in place.
---

# Cloud Bootstrap

Set up and manage cloud provider credentials stored encrypted in the repo. Designed for Claude Code on the Web, where the repo is the only persistent storage across sessions. Supports multiple team members, each with their own encrypted key file and passphrase.

**Requires:** An encryption passphrase in one of these environment variables (checked in order):
- `GCP_CREDENTIALS_KEY`, `AWS_CREDENTIALS_KEY`, or `AZURE_CREDENTIALS_KEY` (provider-specific)
- `CLOUD_CREDENTIALS_KEY` (universal fallback)

Each team member sets their own passphrase. Passphrases are never shared between users.

## Identify Current User

Get the current user's identity from git config:

```bash
USER_EMAIL=$(git config user.email)
if [ -z "$USER_EMAIL" ]; then
  echo "ERROR: git user.email is not set."
  exit 1
fi
```

This email is used to name the per-user encrypted credentials file: `.cloud-credentials.<email>.enc`

## Resolve Credentials Key

Use this logic everywhere the encryption key is needed. Determine the provider from context (the user's request during setup, or `.cloud-config.json` in subsequent sessions), then resolve:

```bash
resolve_credentials_key() {
  local provider="$1"  # gcp, aws, or azure
  case "$provider" in
    gcp)   KEY="${GCP_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    aws)   KEY="${AWS_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    azure) KEY="${AZURE_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    *)     KEY="$CLOUD_CREDENTIALS_KEY" ;;
  esac
  if [ -z "$KEY" ]; then
    echo "ERROR: No credentials key found."
    echo "Set ${provider^^}_CREDENTIALS_KEY or CLOUD_CREDENTIALS_KEY."
    return 1
  fi
  echo "$KEY"
}
```

## Quick Check: Which Phase Am I In?

Determine the current user's email, then:

1. If `.cloud-config.json` does NOT exist, go to **First-Time Setup**
2. If `.cloud-config.json` exists BUT `.cloud-credentials.<user-email>.enc` does NOT, go to **Add Team Member**
3. If `.cloud-credentials.<user-email>.enc` exists, go to **Authenticate (Subsequent Sessions)**

---

## First-Time Setup

This is for the first user setting up cloud access on the repo.

### Step 1: Identify Provider

If not obvious from context, ask the user which cloud provider they use.

Then read the corresponding reference file for provider-specific commands:
- **GCP**: Read `references/gcp.md` in this skill's directory
- **AWS**: Read `references/aws.md` in this skill's directory
- **Azure**: Read `references/azure.md` in this skill's directory

All subsequent steps use provider-specific commands from that reference file.

### Step 2: Gather Info

Ask the user for:
- The project/account identifier (GCP project ID, AWS account ID, or Azure subscription ID)
- Any naming preferences for the service account

Do not guess or assume these values.

### Step 3: Propose Roles

Assess the repo (look at code, config files, README, CLAUDE.md, etc.) and determine which roles/permissions the service account will need.

Present a clear list to the user:

```
Based on this repo, I recommend these roles for the service account:

- [role 1] -- [one-line justification]
- [role 2] -- [one-line justification]

Shall I proceed, or would you like to add/remove any?
```

**Do NOT proceed until the user approves.**

### Step 4: Get Bootstrap Token

Ask the user to generate a short-lived token by running a command locally. Provide the exact command from the provider reference file.

Tell them what permissions their personal account needs to create service accounts and assign roles.

### Step 5: Create Service Account and Encrypt Credentials

Using the bootstrap token and provider-specific commands from the reference file:

1. Create the service account/identity.
2. Grant ONLY the approved roles.
3. Generate credentials (key file or access key pair).
4. Resolve the encryption key using the logic above.
5. Encrypt the credentials **with the user's email in the filename**:
   ```bash
   USER_EMAIL=$(git config user.email)
   echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
     -pass stdin \
     -in credentials.json -out ".cloud-credentials.${USER_EMAIL}.enc"
   ```
6. Save shared config:
   ```bash
   cat > .cloud-config.json << EOF
   {
     "provider": "<gcp|aws|azure>",
     "project_id": "<project/account/subscription identifier>",
     "service_account": "<service account email or ARN or client ID>",
     "roles": ["<role1>", "<role2>"]
   }
   EOF
   ```
7. **Delete the plaintext credentials immediately:**
   ```bash
   rm -f credentials.json
   ```
8. Add to `.gitignore`:
   ```
   # Cloud -- never commit plaintext credentials
   credentials.json
   /tmp/credentials.json
   ```
9. Commit `.cloud-credentials.<email>.enc`, `.cloud-config.json`, and the `.gitignore` update.

### Step 6: Set Up SessionStart Hook

Create a SessionStart hook so the provider's CLI is automatically installed at the start of every Claude Code session. Follow the "SessionStart Hook" instructions in the provider's reference file.

- If `.claude/settings.json` does not exist, create it with the hook configuration from the reference.
- If `.claude/settings.json` already exists, merge the new `SessionStart` hook into the existing `hooks` object. Do not overwrite existing hooks.
- Commit `.claude/settings.json` along with the other files.

This ensures that future sessions (including for new team members) have the CLI available without manual installation.

### Step 7: Update CLAUDE.md

Append a `## Cloud Credentials` section to CLAUDE.md (create the file if it doesn't exist) documenting:

- The provider and project/account identifier
- The service account identity
- The roles granted, with one-line justification for each
- That this is a multi-user setup: each team member has their own `.cloud-credentials.<email>.enc` file
- How to authenticate (the agent handles this automatically via this skill)
- How new team members can join (the agent handles this via the **Add Team Member** flow)
- How to escalate permissions

### Step 8: Done

The bootstrap token is now spent. Do not store it anywhere.

---

## Add Team Member

This flow runs when `.cloud-config.json` exists (the service account is already set up) but the current user has no encrypted credentials file yet.

### Step 1: Read Existing Config

Read `.cloud-config.json` to get the provider, project ID, and service account identity. Read the corresponding provider reference file.

### Step 2: Explain and Get Bootstrap Token

Tell the user:

```
This repo already has cloud access configured:
  Provider: <provider>
  Project: <project_id>
  Service account: <service_account>
  Roles: <roles>

I need to create a new key for this service account, encrypted with your
personal passphrase. This means you won't need anyone else's password.

Please run this on your local machine and paste the result:
  <bootstrap token command from provider reference>
```

Tell them the specific permission needed from the provider reference file (see "Team Member Prerequisites" in each reference).

### Step 3: Create New Key and Encrypt

Using the bootstrap token and provider-specific commands:

1. Create a **new key** for the **existing** service account (do NOT create a new service account). See the "Add Key for Existing Service Account" section in the provider reference.
2. Resolve the encryption key for the current user.
3. Encrypt with the user's email in the filename:
   ```bash
   USER_EMAIL=$(git config user.email)
   echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
     -pass stdin \
     -in credentials.json -out ".cloud-credentials.${USER_EMAIL}.enc"
   ```
4. **Delete the plaintext credentials immediately:**
   ```bash
   rm -f credentials.json
   ```
5. Commit the new `.cloud-credentials.<email>.enc` file.

### Step 4: Ensure SessionStart Hook Exists

Check if `.claude/settings.json` already contains a SessionStart hook for the provider's CLI. If not, add one following the "SessionStart Hook" instructions in the provider's reference file. Commit `.claude/settings.json` if it was created or modified.

### Step 5: Done

The bootstrap token is now spent. The user can now authenticate in future sessions using their own passphrase.

---

## Authenticate (Subsequent Sessions)

Run this every time you need cloud access and are not yet authenticated:

1. Read `.cloud-config.json` to determine the provider.
2. Ensure the provider's CLI is installed by running the installation script from the corresponding reference file. This is a safety net in case the SessionStart hook hasn't run yet.
3. Get the current user's email:
   ```bash
   USER_EMAIL=$(git config user.email)
   ```
4. Read the corresponding provider reference file in this skill's directory.
5. Resolve the encryption key.
6. Decrypt the user's credentials:
   ```bash
   echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
     -pass stdin \
     -in ".cloud-credentials.${USER_EMAIL}.enc" -out /tmp/credentials.json
   ```
7. Activate using the provider-specific commands from the reference file.
8. **Delete `/tmp/credentials.json` immediately after activation.**

---

## Permission Escalation

If any cloud API call fails with 403, "access denied", or equivalent:

1. **Stop.** Do not retry or attempt workarounds.
2. Tell the user:
   - The exact error message
   - The specific role or permission needed
   - Why it is needed
3. Ask the user to:
   - Grant the role to the service account
   - Provide a new bootstrap token if IAM changes require it
4. After the user confirms, retry the operation.
5. Update `.cloud-config.json` roles array and the CLAUDE.md Cloud Credentials section to reflect the new role.

**Never modify IAM policies yourself.**

---

## Proactive Suggestions

When cloud credentials are active, periodically consider whether cloud services could improve the current workflow. If you notice any of these patterns, suggest an improvement to the user:

- **Repeated file processing:** If the same large file is being re-read or re-downloaded every session, suggest uploading it to cloud storage (GCS, S3) or a managed database (BigQuery, Athena) for persistent, queryable access.
- **Long-running tasks:** If a computation is approaching sandbox time limits or memory constraints, suggest running it on a cloud VM with appropriate resources.
- **Manual recurring tasks:** If the user runs the same script or check regularly, suggest deploying it as a scheduled cloud function.
- **File sharing friction:** If outputs need to be shared with collaborators or external participants, suggest uploading to cloud storage and generating shareable links.
- **Growing datasets:** If data is being appended or collected across sessions via CSVs or flat files, suggest migrating to a managed database.

Frame suggestions as questions, not directives: "Would it help if I moved this dataset to BigQuery so we do not have to re-process it every session?" Let the user decide.

---

## Rules

- Never store plaintext credentials in the repo or git history.
- Never modify IAM policies yourself.
- Prefer granular roles over broad roles (e.g., `roles/cloudfunctions.developer` not `roles/editor`; `S3ReadOnlyAccess` not `AdministratorAccess`).
- Always delete `/tmp/credentials.json` immediately after activation.
- If the bootstrap token expires before setup is complete, ask the user for a new one.
- The encryption passphrase is the only secret not stored in the repo. Each user has their own passphrase, never shared.
- Each user's `.cloud-credentials.<email>.enc` file is committed to the repo. This is safe because the file is encrypted and each user's passphrase is independent.
