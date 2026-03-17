---
name: cloud-bootstrap
version: 1.2.2
description: >-
  Manage encrypted cloud-provider credentials (GCP, AWS, Azure) stored in a
  repo for Claude Code on the Web.

  TRIGGER when the user explicitly asks to set up, rotate, or fix cloud
  credentials or service accounts — or when you detect .cloud-config.json or
  .cloud-credentials.*.enc files in the repo — or when a cloud CLI command
  fails with an authentication/permission error (401, 403, "not authenticated",
  "access denied").

  DO NOT TRIGGER for general cloud questions ("what is a VPC?"), SDK usage
  ("how do I call the S3 API in Python?"), or cloud tasks where credentials
  are already working. Only invoke this skill when credential setup,
  encryption, decryption, rotation, or repair is actually needed.
---

# Cloud Bootstrap

Set up and manage cloud provider credentials stored encrypted in the repo. Designed for Claude Code on the Web, where the repo is the only persistent storage across sessions. Supports multiple team members, each with their own encrypted key file and passphrase.

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

1. If `.cloud-config.json` does NOT exist → read `workflows/first-time-setup.md`
2. If `.cloud-config.json` exists BUT `.cloud-credentials.<user-email>.enc` does NOT → read `workflows/add-team-member.md`
3. If `.cloud-credentials.<user-email>.enc` exists → read `workflows/authenticate.md`

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

## Rules

- Never store plaintext credentials in the repo or git history.
- Never modify IAM policies yourself.
- Prefer granular roles over broad roles (e.g., `roles/cloudfunctions.developer` not `roles/editor`; `S3ReadOnlyAccess` not `AdministratorAccess`).
- Always delete `/tmp/credentials.json` immediately after activation.
- If the bootstrap token expires before setup is complete, ask the user for a new one.
- The encryption passphrase is the only secret not stored in the repo. Each user has their own passphrase, never shared.
- Each user's `.cloud-credentials.<email>.enc` file is committed to the repo. This is safe because the file is encrypted and each user's passphrase is independent.
