---
name: cloud-bootstrap
description: Bootstrap and manage cloud service account credentials (GCP, AWS, Azure) for a repo used in Claude Code on the Web. Use this skill whenever the user mentions GCP, Google Cloud, AWS, Amazon Web Services, Azure, service accounts, cloud credentials, IAM, or wants to set up cloud infrastructure for a project. Also trigger when you detect .cloud-credentials.enc or .cloud-config.json in the repo, or when a cloud API call fails with authentication or permission errors. This skill handles both first-time setup (creating service accounts, encrypting keys, persisting config) and subsequent sessions (decrypting and activating credentials). Even if the user just says "deploy to Lambda" or "set up a Cloud Run service" or "create an Azure Function", use this skill first to ensure cloud auth is in place.
---

# Cloud Bootstrap

Set up and manage cloud provider credentials stored encrypted in the repo. Designed for Claude Code on the Web, where the repo is the only persistent storage across sessions.

**Requires:** An encryption passphrase in one of these environment variables (checked in order):
- `GCP_CREDENTIALS_KEY`, `AWS_CREDENTIALS_KEY`, or `AZURE_CREDENTIALS_KEY` (provider-specific)
- `CLOUD_CREDENTIALS_KEY` (universal fallback)

This lets users who work with multiple providers across repos use distinct passphrases per provider, while users with a single provider can just set `CLOUD_CREDENTIALS_KEY`.

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

**Store which env var was used** in `.cloud-config.json` (as `"credentials_key_env"`) so subsequent sessions know which variable to check without re-resolving.

## Quick Check: Which Phase Am I In?

1. If `.cloud-credentials.enc` exists in the repo, go to **Authenticate (Subsequent Sessions)**
2. If `.cloud-credentials.enc` does NOT exist, go to **First-Time Setup**

---

## First-Time Setup

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
4. Resolve the encryption key using the logic above:
   ```bash
   PROVIDER="<gcp|aws|azure>"
   CRED_KEY_ENV="${PROVIDER^^}_CREDENTIALS_KEY"
   KEY="${!CRED_KEY_ENV:-$CLOUD_CREDENTIALS_KEY}"
   if [ -z "$KEY" ]; then
     echo "ERROR: Set ${CRED_KEY_ENV} or CLOUD_CREDENTIALS_KEY."
     exit 1
   fi
   # Remember which env var worked
   if [ -n "${!CRED_KEY_ENV}" ]; then
     USED_ENV="$CRED_KEY_ENV"
   else
     USED_ENV="CLOUD_CREDENTIALS_KEY"
   fi
   ```
5. Encrypt the credentials:
   ```bash
   echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
     -pass stdin \
     -in credentials.json -out .cloud-credentials.enc
   ```
6. Save config (note the `credentials_key_env` field):
   ```bash
   cat > .cloud-config.json << EOF
   {
     "provider": "$PROVIDER",
     "project_id": "<project/account/subscription identifier>",
     "service_account": "<service account email or ARN or client ID>",
     "roles": ["<role1>", "<role2>"],
     "credentials_key_env": "$USED_ENV"
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
9. Commit `.cloud-credentials.enc`, `.cloud-config.json`, and the `.gitignore` update.

### Step 6: Update CLAUDE.md

Append a `## Cloud Credentials` section to CLAUDE.md (create the file if it doesn't exist) documenting:

- The provider and project/account identifier
- The service account identity
- The roles granted, with one-line justification for each
- How to authenticate (decrypt, activate, set project), using the exact commands for the provider
- How to escalate permissions

This ensures future sessions can authenticate without needing this skill installed.

### Step 7: Done

The bootstrap token is now spent. Do not store it anywhere.

---

## Authenticate (Subsequent Sessions)

Run this every time you need cloud access and are not yet authenticated:

1. Read `.cloud-config.json` to determine the provider and which env var holds the key.
2. Read the corresponding provider reference file in this skill's directory.
3. Resolve the encryption key:
   ```bash
   CRED_KEY_ENV=$(jq -r .credentials_key_env .cloud-config.json)
   KEY="${!CRED_KEY_ENV}"
   if [ -z "$KEY" ]; then
     echo "ERROR: $CRED_KEY_ENV is not set."
     exit 1
   fi
   ```
4. Decrypt:
   ```bash
   echo "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 \
     -pass stdin \
     -in .cloud-credentials.enc -out /tmp/credentials.json
   ```
5. Activate using the provider-specific commands from the reference file.
6. **Delete `/tmp/credentials.json` immediately after activation.**

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

## Rules

- Never store plaintext credentials in the repo or git history.
- Never modify IAM policies yourself.
- Prefer granular roles over broad roles (e.g., `roles/cloudfunctions.developer` not `roles/editor`; `S3ReadOnlyAccess` not `AdministratorAccess`).
- Always delete `/tmp/credentials.json` immediately after activation.
- If the bootstrap token expires before setup is complete, ask the user for a new one.
- `GCP_CREDENTIALS_KEY` / `AWS_CREDENTIALS_KEY` / `AZURE_CREDENTIALS_KEY` (or `CLOUD_CREDENTIALS_KEY`) is the only secret not stored in the repo. Everything else is self-contained.
