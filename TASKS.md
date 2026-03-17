# TASKS.md

Planned improvements and open items for cloud-bootstrap.

## Documentation

- [ ] Add a troubleshooting section to SKILL.md covering common failure modes (expired token, wrong passphrase, missing env var, key limit reached)
- [ ] Add examples of `.cloud-config.json` for each provider in README.md
- [ ] Document how to revoke a team member's access end-to-end (delete enc file + provider-side key deletion)
- [ ] Add a "How It Works" diagram (ASCII or Mermaid) showing the encryption/decryption flow

## Features

- [x] Auto-install cloud CLIs — each provider reference now includes CLI installation commands and a SessionStart hook config. SKILL.md creates the hook after first-time setup and verifies it during add-team-member. The authenticate flow also checks as a fallback.
- [ ] Support credential rotation — a workflow for replacing an existing encrypted key without re-bootstrapping
- [ ] Add a verification step after authentication that confirms the credentials actually work (e.g., a lightweight API call per provider)
- [ ] Support multiple cloud providers in the same repo (currently `.cloud-config.json` assumes a single provider)
- [ ] Add an optional `--dry-run` style mode to SKILL.md where the agent shows what it would do without executing

## Security

- [ ] Document threat model explicitly (what is protected, what is not, trust boundaries)
- [ ] Add guidance on passphrase strength requirements
- [ ] Consider adding credential expiry metadata to `.cloud-config.json` so the agent can warn when keys are aging

## Testing

- [ ] Create a test script that validates the encrypt/decrypt round-trip works with a dummy key
- [ ] Add a CI check that ensures all shell snippets in the Markdown files are syntactically valid (e.g., `bash -n`)
