# Changelog

All notable changes to cloud-bootstrap are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/). Versions use [Semantic Versioning](https://semver.org/).

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
