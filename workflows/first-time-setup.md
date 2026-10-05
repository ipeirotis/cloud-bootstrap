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
1a. **Ignore the plaintext files before anything is created**, so an interrupted run can never leave a committable `credentials.json`. Add to `.gitignore` now:
   ```
   # Cloud -- never commit plaintext credentials (written at the repo root
   # during setup; the hooks' decrypted copies live in the system /tmp)
   /credentials.json
   /credentials_clean.json
   /.cloud-setup-pending.json
   ```
   If a run is interrupted, the next session finds what it left and recovers ("Recovering an Interrupted Run" in SKILL.md).
2. Create the service account/identity with the reference's creation snippet, which first records the identity's names in `.cloud-setup-pending.json`. From here on, if any later step fails (a role grant, key creation, encryption), run "Rollback a Failed Setup" in the provider reference before retrying, so a live identity, key or role grant is not left behind and the collision checks do not block the retry. It reads the names from `.cloud-setup-pending.json`, so it works from a fresh shell.
3. Grant ONLY the approved roles.
4. Generate credentials (key file or access key pair).
5. Encrypt the credentials **with the user's email in the filename**:
   ```bash
   USER_EMAIL=$(git config user.email)
   ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   # Encrypt to a private temp file, prove it decrypts to the credential, and
   # only then move it into place in one rename, so a truncated file never
   # appears under the final name. credentials.json stays until step 7: if this
   # run is interrupted anywhere before then, the next session finds it and
   # recovers ("Recovering an Interrupted Run" in SKILL.md).
   TMP_ENC=$(umask 077 && mktemp "${ENC_FILE}.tmp.XXXXXX") \
     || { echo "ERROR: could not create a temp file. Run the provider's setup rollback now (step 2)."; exit 1; }
   if ! { printf '%s\n' "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass stdin \
            -in credentials.json -out "$TMP_ENC" \
          && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$TMP_ENC" \
            | cmp -s - credentials.json \
          && mv -f "$TMP_ENC" "$ENC_FILE"; }; then
     rm -f "$TMP_ENC" "$ENC_FILE" credentials.json
     echo "ERROR: encryption failed. Run the provider's setup rollback now (step 2), then retry setup."
     exit 1
   fi
   ```
   If encryption fails, the snippet deletes the plaintext and stops; then run "Rollback a Failed Setup" for the provider (step 2), so no live, unusable credential is left behind.
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
     "key_ids": {"<email>": "<GCP key ID or Azure secret keyId, omit for AWS>"},
     "roles": ["<role1>", "<role2>"],
     "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   }
   EOF
   ```
   For GCP, fill `key_ids` with the `KEY_ID` from "Create Key" ("Record the key's owner" in `references/gcp.md`); for Azure, with the `keyId` in `credentials.json` (`jq -r .keyId credentials.json`, which is not secret). Offboarding finds a member's credential through this map, without their passphrase.
7. **Delete the plaintext credentials now** (only now: until this point its presence is what marks the setup as unfinished for the next session):
   ```bash
   rm -f credentials.json .cloud-setup-pending.json
   ```
8. Commit `.cloud-credentials.<email>.enc`, `.cloud-config.json`, and the `.gitignore` update (step 1a).

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
