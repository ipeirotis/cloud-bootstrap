# First-Time Setup

This is for the first user setting up cloud access on the repo.

## Step 1: Identify Provider

If not obvious from context, ask the user which cloud provider they use.

Then read the corresponding reference file for provider-specific commands:
- **GCP**: Read `references/gcp.md` in this skill's directory
- **AWS**: Read `references/aws.md` in this skill's directory
- **Azure**: Read `references/azure.md` in this skill's directory

All subsequent steps use provider-specific commands from that reference file.

## Step 2: Gather Info

Ask the user for:
- The project/account identifier (GCP project ID, AWS account ID, or Azure subscription ID)
- Any naming preferences for the service account

Do not guess or assume these values.

## Step 3: Propose Roles

Assess the repo (look at code, config files, README, CLAUDE.md, etc.) and determine which roles/permissions the service account will need.

Present a clear list to the user:

```
Based on this repo, I recommend these roles for the service account:

- [role 1] -- [one-line justification]
- [role 2] -- [one-line justification]

Shall I proceed, or would you like to add/remove any?
```

**Do NOT proceed until the user approves.**

## Step 4: Get Bootstrap Token

Ask the user to generate a short-lived token by running a command locally. Provide the exact command from the provider reference file.

Tell them what permissions their personal account needs to create service accounts and assign roles.

## Step 5: Create Service Account and Encrypt Credentials

Using the bootstrap token and provider-specific commands from the reference file:

1. **Resolve the encryption key first**, using the logic in SKILL.md, before anything is created on the provider side. If no key is set, stop here (SKILL.md, Example 3): otherwise setup would leave a live provider credential and a plaintext `credentials.json` that cannot be encrypted.
2. Create the service account/identity.
3. Grant ONLY the approved roles.
4. Generate credentials (key file or access key pair).
5. Encrypt the credentials **with the user's email in the filename**:
   ```bash
   USER_EMAIL=$(git config user.email)
   echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt \
     -pass stdin \
     -in credentials.json -out ".cloud-credentials.${USER_EMAIL}.enc"
   ```
6. Save shared config (include `created_at` for credential age tracking):
   ```bash
   cat > .cloud-config.json << EOF
   {
     "provider": "<gcp|aws|azure>",
     "project_id": "<project/account/subscription identifier>",
     "service_account": "<service account email or ARN or client ID>",
     "tenant": "<Azure tenant ID, omit for GCP/AWS>",
     "region": "<AWS region, omit for GCP/Azure>",
     "iam_user_prefix": "<AWS user-name prefix, omit for GCP/Azure>",
     "roles": ["<role1>", "<role2>"],
     "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   }
   EOF
   ```
7. **Delete the plaintext credentials immediately:**
   ```bash
   rm -f credentials.json
   ```
8. Add to `.gitignore`:
   ```
   # Cloud -- never commit plaintext credentials (written at the repo root
   # during setup; the hooks' decrypted copies live in the system /tmp)
   /credentials.json
   /credentials_clean.json
   ```
9. Commit `.cloud-credentials.<email>.enc`, `.cloud-config.json`, and the `.gitignore` update.

## Step 6: Set Up SessionStart Hook

Create a SessionStart hook that automatically installs the provider CLI **and** authenticates at the start of every Claude Code session. Follow the "SessionStart Hook" instructions in the provider's reference file.

1. Create `.claude/hooks/cloud-auth.sh` with the script from the provider reference. Make it executable: `chmod +x .claude/hooks/cloud-auth.sh`
2. If `.claude/settings.json` does not exist, create it with the hook configuration from the reference.
3. If `.claude/settings.json` already exists, merge the new `SessionStart` hook into the existing `hooks` object. Do not overwrite existing hooks.
4. Commit `.claude/hooks/cloud-auth.sh` and `.claude/settings.json` along with the other files.

This ensures that future sessions start with the CLI installed and credentials already activated — no manual authentication needed.

## Step 7: Update CLAUDE.md

Append a `## Cloud Credentials` section to the repo's agent-instructions file: `CLAUDE.md`, or `AGENTS.md` when that is the file the repo uses (for example, when `CLAUDE.md` only points to `AGENTS.md`). Create `CLAUDE.md` only if neither exists. Document:

- The provider and project/account identifier
- The service account identity
- The roles granted, with one-line justification for each
- That this is a multi-user setup: each team member has their own `.cloud-credentials.<email>.enc` file
- How to authenticate (the agent handles this automatically via this skill)
- How new team members can join (the agent handles this via the **Add Team Member** flow)
- How to escalate permissions

## Step 8: Done

The bootstrap token is now spent. Do not store it anywhere.
