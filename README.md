# cloud-bootstrap

A skill for [Claude Code on the Web](https://claude.com/product/claude-code) that bootstraps cloud provider credentials (GCP, AWS, Azure) and stores them encrypted in your repo.

## The Problem

Claude Code on the Web has no persistent storage across sessions except the repo itself. If your project needs cloud access, you need a way to store credentials that:

- Survives across sessions
- Travels with the repo
- Doesn't expose secrets in git history
- Lets the agent authenticate without human intervention each session

## How It Works

1. You tell the agent which cloud provider and project to use
2. The agent proposes minimum roles; you approve
3. You generate a short-lived token locally and paste it in
4. The agent creates a service account, encrypts the key with `openssl`, and commits the encrypted file
5. In future sessions, the agent decrypts and authenticates automatically

The only secret not in the repo is the encryption passphrase, which you set as an environment variable in Claude Code on the Web. You can use a provider-specific variable (`GCP_CREDENTIALS_KEY`, `AWS_CREDENTIALS_KEY`, `AZURE_CREDENTIALS_KEY`) or a universal one (`CLOUD_CREDENTIALS_KEY`). The skill checks the provider-specific variable first and falls back to the universal one.

This means if you work with multiple providers across different repos, you can use distinct passphrases per provider. If you only use one provider, just set `CLOUD_CREDENTIALS_KEY` and forget about it.

## Install

Copy the skill into your repo:

```bash
# From the repo root
mkdir -p .claude/skills/cloud-bootstrap/references

curl -o .claude/skills/cloud-bootstrap/SKILL.md \
  https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/SKILL.md

curl -o .claude/skills/cloud-bootstrap/references/gcp.md \
  https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/references/gcp.md

curl -o .claude/skills/cloud-bootstrap/references/aws.md \
  https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/references/aws.md

curl -o .claude/skills/cloud-bootstrap/references/azure.md \
  https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/references/azure.md

git add .claude/skills/cloud-bootstrap
git commit -m "Add cloud-bootstrap skill"
```

Or just tell Claude Code on the Web:

> "Clone the cloud-bootstrap skill from https://github.com/ipeirotis/cloud-bootstrap into `.claude/skills/cloud-bootstrap/` in this repo and commit it."

## Prerequisites

- Encryption passphrase set as an environment variable in Claude Code on the Web: either `GCP_CREDENTIALS_KEY` / `AWS_CREDENTIALS_KEY` / `AZURE_CREDENTIALS_KEY`, or the universal `CLOUD_CREDENTIALS_KEY`
- A cloud account with permission to create service accounts and assign roles
- `openssl` available in the environment (standard on CCoW)

## Supported Providers

| Provider | Bootstrap Command | What Gets Created |
|----------|------------------|-------------------|
| GCP | `gcloud auth print-access-token` | Service account + JSON key |
| AWS | `aws sts get-session-token` | IAM user + access key pair |
| Azure | `az account get-access-token` | Service principal + client secret |

## Files Created in Your Repo

| File | Purpose | Committed? |
|------|---------|------------|
| `.cloud-credentials.enc` | Encrypted service account key | Yes |
| `.cloud-config.json` | Provider, project ID, roles | Yes |
| `CLAUDE.md` (Cloud Credentials section) | Human/agent-readable auth docs | Yes |
| `credentials.json` | **Never** (plaintext key) | `.gitignore`d |

## Security Model

- Credentials are encrypted with AES-256-CBC (via `openssl`)
- Plaintext keys exist only momentarily during setup and authentication, and are deleted immediately
- The agent cannot escalate its own permissions; it must ask you
- Bootstrap tokens expire in ~1 hour
- The encryption passphrase (`GCP_CREDENTIALS_KEY`, `AWS_CREDENTIALS_KEY`, `AZURE_CREDENTIALS_KEY`, or `CLOUD_CREDENTIALS_KEY`) never enters the repo

## License

MIT
