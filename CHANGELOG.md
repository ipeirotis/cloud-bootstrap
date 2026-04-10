# Changelog

All notable changes to cloud-bootstrap are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/). Versions use [Semantic Versioning](https://semver.org/).

## [1.4.0] - 2026-04-10

### Added
- SKILL.md: Expanded YAML trigger description with 13+ explicit trigger phrases for reliable activation
- SKILL.md: Added Overview section written for Claude's skill-matching system
- SKILL.md: Added Output Format specification for consistent user communication
- SKILL.md: Added 5 Examples covering happy paths, edge cases, and negative tests
- SKILL.md: Added specific cloud error codes to trigger list (AADSTS700024, InvalidIdentityToken)
- README: Added version, license, skill, and provider badges
- README: Added "Features at a Glance" section with 8 key capabilities
- README: Added comparison table vs. Secret Manager, Vault, .env, and manual paste
- README: Added ASCII architecture diagram showing session auth flow
- README: Added Quick Start section (3 steps to working cloud access)
- README: Added Troubleshooting table for 5 common issues
- README: Added tagline: "Encrypted cloud credentials that survive Claude Code sessions"

### Changed
- SKILL.md: Tightened DO NOT TRIGGER boundaries to include Terraform/IaC and SDK questions
- SKILL.md: Proactive Suggestions section now scoped to avoid firing during credential workflows

## [1.3.0] - 2026-04-10

### Fixed
- Phase detection now recognizes multi-provider credential file naming (#6)
- SessionStart hooks use `(umask 077 && openssl ...)` for restrictive file permissions (#4)
- SessionStart hooks add `trap 'rm -f /tmp/credentials.json' EXIT` for guaranteed cleanup (#4)
- Credential prechecks run before CLI installation to avoid unnecessary downloads (#5)
- CLI installation and auth commands guarded with conditionals for graceful failure (#5)
- jq command substitutions guarded with `|| exit 0` to handle missing jq or malformed config (#11)
- GCP `curl|bash` install pipeline replaced with split download to detect failures (#12)
- Hook templates check common CLI install paths before attempting downloads (#13)
- Decryption failures now emit explicit warnings instead of failing silently (#14)
- Azure reference uses separate ARM and Graph tokens for correct API scope (#9)
- AWS reference no longer hardcodes us-east-1; region read from config or user input (#7)
- Multi-provider hook uses per-provider error isolation so one failure doesn't block others (#8)
- Authenticate workflow decryption hardened with umask and trap (#10)
- Add-team-member, authenticate, and credential-rotation workflows support multi-provider credential naming (#15)

## [1.2.2] - 2026-03-17

### Fixed
- README manual install now includes all workflow files and VERSION
- update.sh changelog parser uses portable awk (works on macOS/BSD)
- update.sh error message no longer has a broken URL substitution

## [1.2.1] - 2026-03-17

### Fixed
- install.sh and update.sh now download workflow files and VERSION file
- Version detection prefers VERSION file over SKILL.md frontmatter parsing

## [1.2.0] - 2026-03-17

### Changed
- Narrowed SKILL.md trigger description to avoid false positives on general cloud questions or SDK usage
- Added explicit TRIGGER / DO NOT TRIGGER guidance in frontmatter

## [1.1.0] - 2026-03-17

### Changed
- Split SKILL.md into a slim router (~80 lines) plus individual workflow files
- Agent now loads only the relevant workflow per invocation instead of all 500 lines
- New `workflows/` directory with: first-time-setup, add-team-member, authenticate, credential-rotation, permission-escalation, multi-provider, uninstall

## [1.0.0] - 2026-03-17

Initial versioned release. All existing functionality is now tracked under this version.

### Included
- First-time setup workflow (GCP, AWS, Azure)
- Add team member workflow
- Automatic session authentication via SessionStart hook
- Credential rotation
- Permission escalation handling
- Multi-provider support
- Proactive cloud suggestions
- Uninstall workflow
- One-line installer (`install.sh`)
