# TASKS.md

Planned improvements and open items for cloud-bootstrap.

## Documentation

- [ ] Add a troubleshooting section to SKILL.md covering common failure modes (expired token, wrong passphrase, missing env var, key limit reached)
- [ ] Add examples of `.cloud-config.json` for each provider in README.md
- [ ] Document how to revoke a team member's access end-to-end (delete enc file + provider-side key deletion)
- [ ] Add a "How It Works" diagram (ASCII or Mermaid) showing the encryption/decryption flow

## Features

- [x] Auto-install cloud CLIs — each provider reference now includes CLI installation commands and a SessionStart hook config. SKILL.md creates the hook after first-time setup and verifies it during add-team-member. The authenticate flow also checks as a fallback.
- [x] SessionStart auto-authenticate — the SessionStart hook now installs the CLI and decrypts/activates credentials automatically. Sessions start ready-to-go with no agent interaction needed. AWS uses `$CLAUDE_ENV_FILE` to persist env vars.
- [x] Support credential rotation — new "Credential Rotation" section in SKILL.md. Deletes old key on provider side, creates a new one, re-encrypts, and updates `created_at`.
- [x] Post-auth verification — each provider reference now has a "Verify (Smoke Test)" section with a lightweight API call. The authenticate flow runs it after activation.
- [x] Credential expiry tracking — `.cloud-config.json` now includes `created_at`. The authenticate flow warns when credentials are older than 180 days.
- [x] Support multiple cloud providers in the same repo — new "Multi-Provider Setup" section in SKILL.md with `providers` array config format and provider-prefixed credential filenames.
- [x] One-line install script — `install.sh` at repo root, documented in README.
- [x] Uninstall workflow — new "Uninstall" section in SKILL.md with step-by-step cleanup.
- [ ] Add an optional `--dry-run` style mode to SKILL.md where the agent shows what it would do without executing

## Security

- [ ] Document threat model explicitly (what is protected, what is not, trust boundaries)
- [ ] Add guidance on passphrase strength requirements
- [x] Credential expiry metadata — `created_at` field added to `.cloud-config.json`, with 180-day warning in the authenticate flow

## Testing

- [ ] Create a test script that validates the encrypt/decrypt round-trip works with a dummy key
- [ ] Add a CI check that ensures all shell snippets in the Markdown files are syntactically valid (e.g., `bash -n`)
