# CLAUDE.md

This is a Claude Code skill repository — it contains no executable source code, only Markdown documentation that Claude Code reads at runtime.

## Repository Structure

```
.
├── README.md              # Installation instructions and project overview
├── SKILL.md               # Main skill definition (frontmatter + workflows)
├── install.sh             # One-line installer script
├── references/
│   ├── gcp.md             # GCP-specific commands and API reference
│   ├── aws.md             # AWS-specific commands and API reference
│   └── azure.md           # Azure-specific commands and API reference
├── .gitignore             # Blocks credentials.json and /tmp/
└── LICENSE                # MIT
```

## What This Project Does

cloud-bootstrap is a skill for Claude Code on the Web that manages encrypted cloud provider credentials (GCP, AWS, Azure) stored directly in a user's repo. It solves the problem of persisting cloud credentials across Claude Code sessions without exposing secrets in git history.

Key concepts:
- Encrypted credential files per user: `.cloud-credentials.<email>.enc`
- Shared config: `.cloud-config.json`
- Encryption via OpenSSL AES-256-CBC with PBKDF2
- Three workflows: first-time setup, add team member, authenticate

## Development Guidelines

- There is no build step, test suite, or linter — the deliverables are Markdown files.
- When editing SKILL.md, preserve the YAML frontmatter (the `---` block at the top) — Claude Code uses it to decide when to trigger the skill.
- Shell snippets in the docs are meant to be executed by Claude Code at runtime in the user's repo, not here. Ensure they are correct and portable (POSIX-compatible where possible, bash where necessary).
- Keep provider-specific details in `references/<provider>.md`, not in SKILL.md. SKILL.md should contain only the provider-agnostic workflow.
- Encryption/decryption commands must always use `echo "$KEY" | openssl ... -pass stdin` (never `-pass pass:$KEY`) to avoid leaking the key in process listings.

## Conventions

- Commit messages: imperative mood, one sentence, no period at end
- No package manager or dependencies
- All documentation uses standard Markdown (no MDX, no custom extensions)
- Security-sensitive commands should include cleanup steps (e.g., `rm -f credentials.json`)
