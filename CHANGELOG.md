# Changelog

All notable changes to cloud-bootstrap are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/). Versions use [Semantic Versioning](https://semver.org/).

## [1.5.0] - 2026-10-05

Fixes from a multi-round Codex review of a vendored copy (ipeirotis/sql-llm#28).

### Security
- SessionStart hooks (GCP, Azure, multi-provider) run only in Claude Code on the Web (`CLAUDE_CODE_REMOTE=true`). Locally, the fixed decrypted-key path and the shared gcloud/az config let concurrent sessions overwrite each other's identity.
- GCP hooks clear `CLOUDSDK_AUTH_ACCESS_TOKEN` (and persist the unset) before any early exit; it outranks the activated service account.
- AWS hooks clear stale `AWS_SESSION_TOKEN`/`AWS_PROFILE` before using long-lived IAM-user keys.
- Credential rotation: after a suspected compromise, revoke the old key at once (step 9), not step 6; verify the replacement in an isolated config with a caller-identity check before revoking; re-encrypt to a temp file, verify, then rename, so a failed write never destroys the current credential.
- GCP role grants keep the fetched policy's `etag`, `version`, and `auditConfigs` (no lost conditional bindings or concurrent edits).
- Azure service-principal names are repo-specific and collision-checked against both applications and service principals.
- SKILL.md rules: IAM changes happen only inside approved setup steps, with user-approved roles and a user-supplied bootstrap token; pasted bootstrap tokens are the designed handoff and are never stored or echoed.

### Changed
- AWS IAM names are scoped to the repository (`claude-agents-<repo>`, `claude-agent-<repo>-<email>`), since IAM names are unique per account: two repos in one account no longer collide or share a group. Setup records the group (`service_account`) and the new `iam_user_prefix` in `.cloud-config.json`; every workflow derives names through one `iam_user_name` helper. Configs without `iam_user_prefix` keep the pre-1.5 names, unchanged.

### Fixed
- `install.sh` / `update.sh`: download every file with `curl --fail` into a temp dir and install only if all succeed; commit only the skill directory; skip the commit when nothing changed. `update.sh` reads its confirmation from the terminal (stdin is the script under `curl | bash`) and, with no terminal, requires `--yes`.
- New `MANIFEST` lists the distributed files; both scripts read it from the release they install, so new files are picked up.
- AWS bootstrap: `get-session-token` passes MFA (`--serial-number`, `--token-code`), without which its credentials cannot call IAM; the credential handoff uses `aws configure export-credentials`; IAM user names under the repo-scoped prefix keep the email as is (IAM allows `.` and `@`) and add a hash of the email when any character had to be replaced or the name exceeds 64 characters, so `alice.smith@` and `alice-smith@` no longer collide (the legacy `claude-agent` prefix keeps its old names); Add Team Member creates a new IAM user in the group, since access keys belong to users.
- Azure: the bootstrap snippet prints the ARM and Graph tokens; `--skip-assignment` (obsolete) is gone; role grants use the subscription ID from setup step 2 before `.cloud-config.json` exists; the REST path collects the tenant ID before creating anything, uses `curl --fail` with field checks, and deletes a half-created application on failure; role assignments get a GUID without needing `uuidgen`.
- GCP: key creation fails on HTTP errors and validates the key before encrypting; the smoke test mints a token instead of `gcloud projects describe` (which needs the Cloud Resource Manager API); first-time prerequisites include Service Account Key Admin, which holds `iam.serviceAccountKeys.create`.
- All standalone and multi-provider hooks run the per-file 180-day age check; the multi-provider fallback reads each provider's own `created_at`.
- Snippets stop on the first failed mutation: AWS `create-user` (a taken name would hand the member another member's identity), GCP `getIamPolicy`/`setIamPolicy`, and the Azure name-collision lookups (a failed lookup is not "no collision").
- First-time setup writes the Cloud Credentials section to `CLAUDE.md` or `AGENTS.md`, whichever the repo uses; uninstall removes it from either, and permission escalation updates it there.
- Setup, Add Team Member, and rotation resolve the encryption passphrase before any provider-side change, so a missing passphrase never leaves a live, unencryptable key.
- Adding a second provider now provisions it (approved roles, bootstrap token, identity, encrypted key) before migrating the config and hook.
- The multi-provider hook removes the shared plaintext `/tmp/credentials.json` on any exit; AWS member removal uses the configured group.
- GCP role grants bind to the service account setup actually created (`SA_EMAIL`, or the configured one later), never a hard-coded name, and use a private `mktemp -d` work directory instead of fixed `/tmp` paths.
- Credential age reads `git log --follow --diff-filter=AM`, so the `git mv` in a multi-provider migration no longer resets every key's age.
- Rotation: the AWS compromise path derives `IAM_USER` before revoking; the GCP and Azure isolated verifications keep their failure status instead of ending on the cleanup.
- AWS first-time setup rolls back the group/user/keys it created when a later step fails, and policy grants derive the group in their own snippet.
- The multi-provider sketches in Authenticate and SKILL.md are valid bash (an `if` body was only a comment).
- Azure hooks treat a failed `az account set` as a failed login (log out, report it) instead of running against the default subscription.
- GCP hooks (standalone and multi-provider) confirm that the configured project was selected and otherwise log the account out, instead of leaving an earlier cached project active.
- GCP keys are recorded per member in a non-secret `key_ids` map in `.cloud-config.json` (setup, Add Team Member, rotation), so offboarding can find a departed member's key; key deletion fails on HTTP errors and removes the member's `.enc` and map entry only after Google confirms.
- Rotation retries GCP replacement-key verification with backoff (new keys can take a minute to work) and, on final failure, deletes the unverified key and its plaintext.
- AWS Add Team Member rolls back the user, membership, and keys it created on failure; the prerequisite lists include the IAM actions rollback needs.
- Azure CLI setup writes `credentials.json` under `umask 077`; the role-grant snippets read the app id from the `providers[]` entry in multi-provider configs.
- Azure Add Team Member validates the tenant and resolves the application before `addPassword`, fails on HTTP errors, and requires `secretText`; Secret Management resolves the application itself and deletes a member's `.enc` only after `removePassword` returns 204.
- Key Limits no longer claims unlimited client secrets: entries count against a shared per-application manifest limit, so add-member lists existing secrets and prunes first.
- Azure service-principal names are a sanitized repo slug plus a random per-run suffix: safe inside JSON and OData strings, and concurrent setups can no longer race to the same name (which `create-for-rbac` would reuse).
- Azure REST setup documents a "Rollback a Failed Setup" step (delete the half-created application and the local plaintext) for failures after the creation block, whose trap cannot span later snippets; first-time setup says to undo a created identity before retrying on every provider.
- GCP service-account creation fails on any HTTP error (409 = the account already exists) instead of continuing to grant roles and create keys for a pre-existing account.
- Uninstall removes the `.gitignore` rules setup actually adds (`/credentials.json`, `/credentials_clean.json`), plus the pre-1.5 forms.
- Setup's `.gitignore` entries are anchored to the repo root (`/credentials.json`, `/credentials_clean.json`); the repo-relative `/tmp/` entry, which never covered the system `/tmp`, is gone.

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
