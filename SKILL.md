---
name: cloud-bootstrap
metadata:
  version: "1.5.0"
description: >-
  Manages encrypted cloud-provider credentials (GCP, AWS, Azure) stored in a
  repo so they persist across Claude Code sessions.

  TRIGGER when the user asks to set up, configure, connect, bootstrap, add,
  rotate, fix or encrypt cloud credentials or a service account ("connect to
  GCP/AWS/Azure", "my cloud command failed"), to store credentials in the
  repo, to authenticate to the cloud, or to add a team member to cloud
  access. Also trigger on .cloud-config.json or .cloud-credentials.*.enc
  files in the repo, or when a cloud CLI command fails with an
  authentication or permission error (401, 403, "not authenticated",
  "access denied", "could not refresh access token", "InvalidIdentityToken",
  "AADSTS700024").

  DO NOT TRIGGER for general cloud questions, SDK or API usage, Terraform or
  IaC, or cloud tasks whose credentials already work. Invoke only when
  credential setup, encryption, decryption, rotation or repair is needed.
---

# Cloud Bootstrap

## Overview

This skill manages encrypted cloud-provider credentials (GCP, AWS, Azure) stored directly in a repository for Claude Code on the Web. When activated, it detects the current authentication state — whether this is a first-time setup, a new team member joining, or a returning session that needs re-authentication — and executes the appropriate workflow. It handles the full credential lifecycle: initial setup, team member onboarding, session authentication, key rotation, permission escalation, multi-provider configuration, and cleanup.

**Requires:** An encryption passphrase in one of these environment variables (checked in order):
- `GCP_CREDENTIALS_KEY`, `AWS_CREDENTIALS_KEY`, or `AZURE_CREDENTIALS_KEY` (provider-specific)
- `CLOUD_CREDENTIALS_KEY` (universal fallback)

Each team member sets their own passphrase. Passphrases are never shared between users.

## Identify Current User

```bash
USER_EMAIL=$(git config user.email)
if [ -z "$USER_EMAIL" ]; then
  echo "ERROR: git user.email is not set."
  exit 1
fi
```

This email is used to name the per-user encrypted credentials file: `.cloud-credentials.<email>.enc`

## Resolve Credentials Key

Use this logic everywhere the encryption key is needed. Determine the provider from context (the user's request during setup, or `.cloud-config.json` in subsequent sessions), then resolve. The function sets `KEY` and never prints it, so the passphrase stays out of terminal output and transcripts:

```bash
resolve_credentials_key() {   # sets KEY; prints nothing on success
  local provider="$1"  # gcp, aws, or azure
  case "$provider" in
    gcp)   KEY="${GCP_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    aws)   KEY="${AWS_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    azure) KEY="${AZURE_CREDENTIALS_KEY:-$CLOUD_CREDENTIALS_KEY}" ;;
    *)     KEY="$CLOUD_CREDENTIALS_KEY" ;;
  esac
  if [ -z "$KEY" ]; then
    echo "ERROR: No credentials key found." >&2
    echo "Set ${provider^^}_CREDENTIALS_KEY or CLOUD_CREDENTIALS_KEY." >&2
    return 1
  fi
}

# Usage: call it directly (not in $(...)), then use $KEY without echoing it
resolve_credentials_key gcp || exit 1
```

## Quick Check: Which Phase Am I In?

Determine the current user's email, then:

0. **First, look for an interrupted run.** First-time setup and adding a provider record the new identity's non-secret names in `.cloud-setup-pending.json` before creating it; setup, Add Team Member and rotation keep the new credential's plaintext in `credentials.json` at the repository root until all their bookkeeping is done, and encrypt through a `.cloud-credentials.*.tmp.*` file. If any of these exists, a previous run stopped part-way (possibly in another shell, where no trap could clean up) and a live provider credential may be untracked. Do not start a new workflow; follow "Recovering an Interrupted Run" below first.
   Also check `.cloud-config.json` (in any `providers[]` entry) for `rotating[<user-email>]` or `revoked_early[<user-email>]`. Either one means this user's rotation stopped before step 8 recorded the replacement: read `workflows/credential-rotation.md` and resume it at step 4, never Authenticate. After `revoked_early` the old key is already deleted, so the current `.enc` no longer works until the replacement exists.
   A non-empty top-level `unrevoked` list names credentials an earlier run could not revoke (entries marked `ambiguous` are candidates to check). Before continuing, tell the user which entries are there and offer to revoke them (offboarding for a departed member's entries, or by hand with a bootstrap token), so they are not left live silently.
   A non-empty `revoke_pending[<user-email>]` means the replacement is in place but old credentials are still live (rotation step 9 did not finish). Authenticate as usual, then tell the user and resume rotation at step 9, which needs a bootstrap token; do not leave the old credentials active silently.
1. If `.cloud-config.json` does NOT exist → read `workflows/first-time-setup.md`
2. If `.cloud-config.json` exists, check for the user's encrypted credentials file. The file may use **either** naming convention:
   - Single-provider: `.cloud-credentials.<user-email>.enc`
   - Multi-provider: `.cloud-credentials.<provider>.<user-email>.enc`

   To detect multi-provider mode, check whether `.cloud-config.json` contains a `providers` array:
   ```bash
   if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then
     # Multi-provider: check for .cloud-credentials.<provider>.<email>.enc for each provider
     PROVIDERS=$(jq -r '.providers[].provider' .cloud-config.json)
   else
     # Single-provider: check for .cloud-credentials.<email>.enc
     :
   fi
   ```
   If **no** matching credential file exists for the current user → read `workflows/add-team-member.md`

   In multi-provider mode, evaluate **each** provider independently: if the
   current user is missing the credential file for *any* configured provider,
   treat that provider as an add-team-member case (read
   `workflows/add-team-member.md` for it) — even if files for other providers
   already exist. Do not short-circuit to authenticate just because one match
   was found, or the missing provider is silently skipped until a command fails.
3. If a matching credential file exists for every configured provider → read `workflows/authenticate.md`

For other operations, read the corresponding workflow file in this skill's `workflows/` directory:
- **Permission escalation** (403 / access denied errors) → `workflows/permission-escalation.md`
- **Credential rotation** (age warning, suspected compromise) → `workflows/credential-rotation.md`
- **Multi-provider setup** (adding a second cloud provider) → `workflows/multi-provider.md`
- **Uninstall** (removing cloud-bootstrap from the repo) → `workflows/uninstall.md`

Read **only** the workflow file you need. Do not read all of them.

---

## Proactive Suggestions

When cloud credentials are active, periodically consider whether cloud services could improve the current workflow:

- **Repeated file processing** → suggest cloud storage (GCS, S3) or managed database (BigQuery, Athena)
- **Long-running tasks** → suggest a cloud VM with appropriate resources
- **Manual recurring tasks** → suggest a scheduled cloud function
- **File sharing friction** → suggest cloud storage with shareable links
- **Growing datasets** → suggest migrating from flat files to a managed database

Frame suggestions as questions, not directives. Let the user decide.

---

## Output Format

When executing any workflow, follow these communication standards:

- **Before each major step:** Tell the user what you are about to do and why, in one sentence.
- **After each major step:** Confirm what happened. Show the command output if relevant.
- **For errors:** State what failed, what the likely cause is, and what the user should do next. Do NOT guess or retry silently.
- **For credential operations:** Always confirm the file name and path of any file created, encrypted, or deleted.
- **Final summary:** After completing a workflow, provide a short checklist of what was done and what the user should verify.
- **Do NOT** add unsolicited suggestions about cloud architecture, cost optimization, or alternative services during credential workflows. Stay focused on the credential task.
- **Do NOT** output raw credentials, keys, or passphrases to the chat. If you need to show a file's contents for debugging, show only the first and last 4 characters.
- **Bootstrap tokens are the one thing the user pastes in.** Setup, add-member, and rotation need the user's short-lived (~1 hour) bootstrap token(s), which they paste into the session; that is the designed handoff, not an exception to the rule above. Use them only for the current workflow, never write them to the repo or echo them back, and keep any copy in a private temp file deleted when the workflow ends. If the user prefers not to paste a token, give them the exact commands to run themselves instead.

## Discarding an Unusable New Credential

When a credential this skill just created cannot be used (verification, decoding, or encryption failed), revoke it before stopping, from the repository root:

```bash
bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh <gcp|aws|azure> [key|member]
```

It finds everything it needs from `credentials.json`, `.cloud-config.json` and the provider (with the bootstrap token in the environment), revokes the key or secret (`member` also deletes a new AWS member's user), and deletes the plaintext. If revocation fails, it records the non-secret ID under `unrevoked` in `.cloud-config.json`: commit that, and revoke it by hand later.

## Recovering an Interrupted Run

First-time setup and adding a provider write `.cloud-setup-pending.json` (gitignored, not secret) before creating the identity: the provider and the names a rollback needs, which otherwise live only in the shell that created them. It is deleted once `.cloud-config.json` describes the identity.

When step 0 of the phase check finds `.cloud-setup-pending.json`, `credentials.json` or a `.cloud-credentials.*.tmp.*` file, decide from what is on disk (`ENC_FILE` is the current user's credential file for the provider in `credentials.json`; `KEY` is their passphrase):

1. **Encryption finished.** `ENC_FILE` exists and decrypts to exactly `credentials.json`:
   ```bash
   printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$ENC_FILE" | cmp -s - credentials.json && echo finished
   ```
   Only bookkeeping was left. Delete the temp files, then finish the interrupted workflow from its step after encryption: First-Time Setup from step 6 of Step 5 (write `.cloud-config.json`) through its item 7 (the SessionStart hook and the commit), Multi-Provider steps 3 to 5, Add Team Member from step 4 of Step 3 (GCP `key_ids`) through Step 4 (the SessionStart hook), or rotation step 8. Those steps read the IDs from `credentials.json`: run them, commit, and only then delete `.cloud-setup-pending.json` and, last, `credentials.json` (a record left without the plaintext would read as an unfinished setup and be rolled back).
2. **First-time setup or provider addition, not finished.** Otherwise, if `.cloud-setup-pending.json` exists: run "Rollback a Failed Setup" in the reference for its `provider` (a record marked `member_only` comes from an AWS Add Team Member; its rollback removes only that member's user). A record marked `ambiguous` or `ambiguous_group` may name an identity another setup created at the same time: the rollback stops instead of touching it. Ask the user, then re-run it with `CONFIRM_SA=1` (GCP), `CONFIRM_USER=1` or `CONFIRM_GROUP=1` (AWS) only if the identity is this run's, or delete the record if it is not. It reads the identity's names from that file, removes the identity's role grants, the identity and its keys, and deletes the file only when everything is gone. Then delete `credentials.json`, the temp files, and any uncommitted `.cloud-credentials` file for that provider (and, for a first-time setup, an uncommitted `.cloud-config.json`), and start that workflow again. A setup started before this record existed has no such file: if `.cloud-config.json` is not in the last commit, treat it the same way and give the rollback the identity's names by hand.
3. **Add Team Member or rotation, not finished.** Otherwise the new credential in `credentials.json` was never safely stored. Revoke it and delete the temp files: `bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh PROVIDER MODE` with `MODE=key` for a rotation (`rotating[<email>]` is set in `.cloud-config.json`, or the user's `.enc` is committed), else `MODE=member` (Add Team Member; for AWS this also deletes the new IAM user). Then restart that workflow; a rotation resumes at its step 4.

A run interrupted after the plaintext is gone needs no recovery here: the workflows delete `credentials.json` only once everything is recorded and committed, and a rotation that stopped before step 8 is resumed from its `rotating` record.

## Examples

### Example 1: First-time setup (happy path)

**User says:** "Set up GCP credentials for this project"

**Expected behavior:**
1. Check for `.cloud-config.json` — not found, so load `workflows/first-time-setup.md`
2. Ask the user for: cloud provider (GCP confirmed), project ID, desired roles
3. Propose minimum roles (e.g., `roles/storage.objectAdmin` instead of `roles/editor`)
4. Ask the user to run `gcloud auth print-access-token` locally and paste the token
5. Create the service account, generate a key, encrypt it, commit `.cloud-credentials.<email>.enc` and `.cloud-config.json`
6. Confirm: "Setup complete. Encrypted credentials committed. Next session will authenticate automatically."

### Example 2: Returning session (happy path)

**User says:** "Deploy this Cloud Function" (but credentials are not yet active this session)

**Expected behavior:**
1. Detect `.cloud-config.json` and `.cloud-credentials.<email>.enc` exist
2. Load `workflows/authenticate.md`
3. Decrypt credentials, activate the CLI, verify with a smoke test
4. Then proceed with the user's original request (deploying the function)

### Example 3: Missing encryption key (edge case)

**User says:** "Set up AWS access"

**Expected behavior:**
1. Check for `AWS_CREDENTIALS_KEY` and `CLOUD_CREDENTIALS_KEY` — both unset
2. **Stop immediately.** Tell the user: "No encryption passphrase found. Please set `AWS_CREDENTIALS_KEY` or `CLOUD_CREDENTIALS_KEY` as an environment variable in Claude Code on the Web, then try again."
3. Do NOT proceed with setup. Do NOT prompt the user to type a passphrase into the chat.

### Example 4: Wrong skill activation (negative test)

**User says:** "How do I create a VPC in AWS?"

**Expected behavior:** Do NOT activate this skill. This is a general cloud question, not a credential management request. Let Claude answer normally.

### Example 5: Permission error mid-task (edge case)

**User says:** "Upload this file to GCS" → command fails with 403

**Expected behavior:**
1. Recognize this as a permission error, load `workflows/permission-escalation.md`
2. Tell the user which role is likely needed (e.g., `roles/storage.objectAdmin`)
3. Ask the user to grant the role via their admin console
4. Do NOT attempt to modify IAM policies directly

## Rules

- Run one workflow at a time per checkout. The interrupted-run markers (`credentials.json`, `.cloud-setup-pending.json`) live at fixed paths in the working tree, so two setup, onboarding or rotation runs in the same checkout would share them. Each Claude Code on the Web session has its own checkout, so separate sessions do not collide.
- Never store plaintext credentials in the repo or git history.
- Never modify IAM policies on your own initiative. The one exception is the role grants inside First-Time Setup (and an AWS member's user in Add Team Member): there the user has approved the exact roles in Step 3 and supplied a short-lived bootstrap token for that purpose, and only those approved grants are made. Everything else, including any 403 / permission escalation, goes to the user to grant.
- Prefer granular roles over broad roles (e.g., `roles/cloudfunctions.developer` not `roles/editor`; `S3ReadOnlyAccess` not `AdministratorAccess`).
- Always delete `/tmp/credentials.json` immediately after activation.
- If the bootstrap token expires before setup is complete, ask the user for a new one.
- The encryption passphrase is the only secret not stored in the repo. Each user has their own passphrase, never shared.
- Each user's `.cloud-credentials.<email>.enc` file is committed to the repo. This is safe because the file is encrypted and each user's passphrase is independent.
