# cloud-bootstrap

A skill for [Claude Code on the Web](https://claude.com/product/claude-code) that bootstraps cloud provider credentials (GCP, AWS, Azure) and stores them encrypted in your repo.

## The Problem

Claude Code on the Web has no persistent storage across sessions except the repo itself. If your project needs cloud access, you need a way to store credentials that:

- Survives across sessions
- Travels with the repo
- Doesn't expose secrets in git history
- Lets the agent authenticate without human intervention each session

## How It Works

**First user (one-time setup):**

1. You tell the agent which cloud provider and project to use
2. The agent proposes minimum roles; you approve
3. You generate a short-lived token locally and paste it in
4. The agent creates a service account, encrypts the key with `openssl`, and commits the encrypted file
5. In future sessions, the agent decrypts and authenticates automatically

**Additional team members:**

1. A teammate opens the repo in Claude Code on the Web
2. The agent sees the existing cloud config but no credentials for this user
3. The teammate generates a short-lived token and pastes it in
4. The agent creates a new key for the same service account, encrypted with the teammate's own passphrase
5. No passwords are shared between team members

Each person's encrypted credentials are stored as `.cloud-credentials.<git-email>.enc`. The service account, roles, and project config are shared.

The only secret not in the repo is the encryption passphrase, which you set as an environment variable in Claude Code on the Web. You can use a provider-specific variable (`GCP_CREDENTIALS_KEY`, `AWS_CREDENTIALS_KEY`, `AZURE_CREDENTIALS_KEY`) or a universal one (`CLOUD_CREDENTIALS_KEY`). The skill checks the provider-specific variable first and falls back to the universal one.

This means if you work with multiple providers across different repos, you can use distinct passphrases per provider. If you only use one provider, just set `CLOUD_CREDENTIALS_KEY` and forget about it.

## Install

**One-liner** (from your repo root):

```bash
curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/install.sh | bash
```

**Manual install** (if you prefer to see each step):

```bash
# From the repo root
BASE=https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main
DEST=.claude/skills/cloud-bootstrap

mkdir -p "$DEST/references" "$DEST/workflows"

for FILE in \
  SKILL.md VERSION \
  references/gcp.md references/aws.md references/azure.md \
  workflows/first-time-setup.md workflows/add-team-member.md \
  workflows/authenticate.md workflows/credential-rotation.md \
  workflows/permission-escalation.md workflows/multi-provider.md \
  workflows/uninstall.md; do
  curl -sSL "$BASE/$FILE" -o "$DEST/$FILE"
done

git add "$DEST"
git commit -m "Add cloud-bootstrap skill"
```

**Or** just tell Claude Code on the Web:

> "Clone the cloud-bootstrap skill from https://github.com/ipeirotis/cloud-bootstrap into `.claude/skills/cloud-bootstrap/` in this repo and commit it."

## Updating

Check which version you have and whether a newer one is available:

```bash
curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/update.sh | bash
```

This will:
1. Show your installed version and the latest version
2. Display the changelog entries you'd be getting
3. Ask for confirmation before updating

You can also check your installed version at any time: `cat .claude/skills/cloud-bootstrap/VERSION`.

## Prerequisites

- Encryption passphrase set as an environment variable in Claude Code on the Web: either `GCP_CREDENTIALS_KEY` / `AWS_CREDENTIALS_KEY` / `AZURE_CREDENTIALS_KEY`, or the universal `CLOUD_CREDENTIALS_KEY`
- A cloud account with permission to create service accounts and assign roles
- `openssl` available in the environment (standard on CCoW)

## Supported Providers

| Provider | Bootstrap Command | What Gets Created | Team Limit |
|----------|------------------|-------------------|------------|
| GCP | `gcloud auth print-access-token` | Service account + JSON key per user | ~10 (keys per SA) |
| AWS | `aws sts get-session-token` | IAM group + IAM user per team member | Unlimited |
| Azure | `az account get-access-token` | Service principal + client secret per user | Unlimited |

## Files Created in Your Repo

| File | Purpose | Committed? |
|------|---------|------------|
| `.cloud-credentials.<email>.enc` | Encrypted key, one per team member | Yes |
| `.cloud-config.json` | Provider, project ID, roles (shared) | Yes |
| `.claude/hooks/cloud-auth.sh` | SessionStart hook: installs CLI + authenticates | Yes |
| `.claude/settings.json` | Hook configuration | Yes |
| `CLAUDE.md` (Cloud Credentials section) | Human/agent-readable auth docs | Yes |
| `credentials.json` | **Never** (plaintext key) | `.gitignore`d |

**Multi-provider repos:** When using multiple providers, credential files are named `.cloud-credentials.<provider>.<email>.enc` and `.cloud-config.json` uses a `providers` array format. See SKILL.md for details.

## Security Model

- Each team member's credentials are encrypted with their own passphrase (never shared)
- Credentials are encrypted with AES-256-CBC (via `openssl`)
- Plaintext keys exist only momentarily during setup and authentication, and are deleted immediately
- The agent cannot escalate its own permissions; it must ask you
- Bootstrap tokens expire in ~1 hour
- Encryption passphrases never enter the repo
- Revoking a team member's access: delete their `.cloud-credentials.<email>.enc` file and remove their key/user from the cloud provider

## License

MIT
