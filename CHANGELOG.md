# Changelog

All notable changes to cloud-bootstrap are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/). Versions use [Semantic Versioning](https://semver.org/).

## [1.5.0] - 2026-10-05

Fixes from a multi-round Codex review of a vendored copy (ipeirotis/sql-llm#28).

### Security
- SessionStart hooks (GCP, AWS, Azure, multi-provider) run only in Claude Code on the Web (`CLAUDE_CODE_REMOTE=true`). Locally, the fixed decrypted-key path and the shared gcloud/az config let concurrent sessions overwrite each other's identity, and the AWS hook would replace the developer's own AWS identity.
- GCP hooks clear `CLOUDSDK_AUTH_ACCESS_TOKEN` (and persist the unset) before any early exit; it outranks the activated service account.
- AWS hooks clear stale `AWS_SESSION_TOKEN`/`AWS_PROFILE` before using long-lived IAM-user keys.
- Credential rotation: after a suspected compromise, revoke the old key at once (step 9), not step 6; verify the replacement in an isolated config with a caller-identity check before revoking; re-encrypt to a temp file, verify, then rename, so a failed write never destroys the current credential.
- GCP role grants keep the fetched policy's `etag`, `version`, and `auditConfigs` (no lost conditional bindings or concurrent edits).
- Azure service-principal names are repo-specific and collision-checked against both applications and service principals.
- SKILL.md rules: IAM changes happen only inside approved setup steps, with user-approved roles and a user-supplied bootstrap token; pasted bootstrap tokens are the designed handoff and are never stored or echoed.

### Changed
- AWS IAM names are scoped to the repository (`claude-agents-<repo>-<suffix>`, `claude-agent-<repo>-<suffix>-<email>`, with a random suffix chosen at setup), since IAM names are unique per account: two repos in one account, even with the same directory name, no longer collide or share a group. Setup records the group (`service_account`) and the new `iam_user_prefix` in `.cloud-config.json`; every workflow derives names through one `iam_user_name` helper. Configs without `iam_user_prefix` keep the pre-1.5 names, unchanged.

### Fixed
- `install.sh` / `update.sh`: download every file with `curl --fail` into a temp dir and install only if all succeed; commit only the skill directory; skip the commit when nothing changed. `update.sh` reads its confirmation from the terminal (stdin is the script under `curl | bash`) and, with no terminal, requires `--yes`.
- New `MANIFEST` lists the distributed files; both scripts read it from the release they install, so new files are picked up.
- AWS bootstrap: `get-session-token` passes MFA (`--serial-number`, `--token-code`), without which its credentials cannot call IAM; the credential handoff uses `aws configure export-credentials`; IAM user names under the repo-scoped prefix keep the email as is (IAM allows `.` and `@`) and add a hash of the email when any character had to be replaced or the name exceeds 64 characters, so `alice.smith@` and `alice-smith@` no longer collide (the legacy `claude-agent` prefix keeps its old names); Add Team Member creates a new IAM user in the group, since access keys belong to users.
- Azure: the bootstrap snippet prints the ARM and Graph tokens; `--skip-assignment` (obsolete) is gone; role grants use the subscription ID from setup step 2 before `.cloud-config.json` exists; the REST path collects the tenant ID before creating anything, uses `curl --fail` with field checks, and deletes a half-created application on failure; role assignments get a GUID without needing `uuidgen`.
- GCP: key creation fails on HTTP errors and validates the key before encrypting; the smoke test mints a token instead of `gcloud projects describe` (which needs the Cloud Resource Manager API); first-time prerequisites include Service Account Key Admin, which holds `iam.serviceAccountKeys.create`.
- All standalone and multi-provider hooks run the per-file 180-day age check; the multi-provider fallback reads each provider's own `created_at`.
- Snippets stop on the first failed mutation: AWS `create-user` (a taken name would hand the member another member's identity), GCP `getIamPolicy`/`setIamPolicy`, and the Azure name-collision lookups (a failed lookup is not "no collision").
- Interrupted runs are recoverable from any shell: setup, Add Team Member and rotation keep `credentials.json` until every record is written, first-time encryption is atomic, and the phase check now starts by looking for a leftover `credentials.json` or temp `.enc` ("Recovering an Interrupted Run" in SKILL.md).
- GCP and Azure create calls classify the outcome by HTTP status: 4xx means nothing was created; a 5xx or a transport failure is ambiguous and triggers cleanup. An ambiguous GCP key is recorded as `ambiguous` under `unrevoked` instead of deleted (GCP keys carry no owner, so it could be a teammate's); Azure removes only a secret absent from the list taken before the call.
- `discard-credential.sh` treats an already-deleted credential as gone and clears its `unrevoked` entry; rotation step 8 recognises a rerun after it already succeeded; Azure offboarding resolves the application itself; AWS offboarding checks the account first; manual GCP activation stops when the project cannot be selected; the Azure REST setup rolls back on INT/TERM/HUP.
- GCP hooks clear `CLOUDSDK_AUTH_ACCESS_TOKEN` before every config-related exit (the multi-provider hook when GCP is configured or the config is unreadable); a service account whose creation response is unusable is deleted; the Azure CLI setup rewrites `credentials.json` through a temp file outside the repository; Azure offboarding and rotation count a secret the app no longer lists as removed; the Azure setup rollback deletes the service principal's role assignments before the application.
- AWS rotation: step 8 requires a readable replacement key ID (as for GCP and Azure) before queueing the old key, and step 9 checks the bootstrap account before looking keys up; `discard-credential.sh` checks it too.
- First-time setup and adding a provider record the new identity's non-secret names in `.cloud-setup-pending.json` (gitignored) before creating it, keep it and `credentials.json` until the config describes the identity, and every provider now has a "Rollback a Failed Setup" that reads it from any shell: GCP removes the account's project bindings before deleting it, AWS deletes user, memberships, policies and group, Azure deletes role assignments before the application (and keeps the application while any remain). Ambiguous Azure secrets are recorded for review instead of removed; AWS offboarding retries continue from the user's current state.
- The GCP service account ID gets a random per-run suffix by default (an ambiguous failure under a user-chosen ID keeps the account for the user to check); AWS hooks activate keys only when `sts get-caller-identity` matches the configured account; `discard-credential.sh aws member` finds the new member's user from the config when `credentials.json` holds no key ID; the phase check resumes an interrupted rotation (`rotating` or `revoked_early` set) at step 4 instead of authenticating.
- GCP Create Key traps INT/TERM/HUP from the request until `credentials.json` exists (revoking the key named in a complete response, else recording candidates); adding a provider renames the legacy credential files before rewriting the config and keeps the recovery markers until both are done; AWS rotation deletes `revoke_pending` keys before creating a replacement (two-key limit); the AWS setup prerequisites list the permissions rotation and cleanup use.
- GCP hooks and manual activation use a decrypted key only when its `client_email` is the configured service account; the phase check tells the user about a non-empty `revoke_pending` and resumes rotation step 9.
- GCP hooks undo an earlier activation (stored account, ADC key, persisted export) whenever a run does not renew it; Azure hooks and manual activation require the credential's `appId` to match the configured application; AWS hooks require the caller ARN to be this member's IAM user; `discard-credential.sh` refuses AWS lookups without a configured or pending account; Azure Add Client Secret traps signals from the request until `credentials.json` exists; Azure setup requires the subscription before creating anything and records it; AWS Add Team Member records the member's user (`member_only`) before creating it, and the AWS rollback then leaves the shared group alone; a provider migration commits the rename together with the new config; the README's manual install stages downloads before replacing files.
- Uninstall deletes leftover plaintext and the setup record before removing their ignore rules; provider migration keeps the top-level `unrevoked` list; offboarding clears `revoked_early`; AWS first-time setup records the IAM user (confirmed absent) before creating it, with atomic record writes; `discard-credential.sh aws key` removes the unrecorded key of a rotation that lost its key ID.
- AWS and Azure hooks (single and multi-provider) undo an earlier activation when a run does not renew it (persisted key exports; az's cached login); AWS manual activation requires this member's user in this account before persisting keys; the Azure rollback stops if the application lookup fails; Add Team Member's interrupt handler removes a credential file it just installed; every workflow commits before deleting the plaintext recovery marker, and Add Team Member commits `.cloud-config.json` for every provider.
- The README's manual install commits only the skill path; `discard-credential.sh` refuses an Azure `credentials.json` whose app is not the configured one (or the setup record's); Authenticate's age fallback reads the provider's own `created_at` in multi-provider configs; uninstall removes only the hook whose command runs `.claude/hooks/cloud-auth.sh`, not every command containing that file name.
- `discard-credential.sh` revokes a GCP or Azure `CRED_ID` override only when it is provably this member's (recorded for them, the key in `credentials.json`, an Azure secret labelled for them, or `CRED_ID_FROM_RESPONSE=1` from the skill's own create snippets); any other override is recorded as ambiguous. Once GCP is configured, Create Key, List Keys, offboarding and `discard-credential.sh` take the project and service account from the config and refuse conflicting shell values. AWS offboarding clears each deleted key's `unrevoked` entry as it goes, so a retry after a partial run leaves no stale entries. SKILL.md states that workflows run one at a time per checkout.
- Add Team Member's cleanup removes the destination `.enc` only when it is this run's ciphertext (an overlapping run may have installed its own); AWS offboarding clears only the `unrevoked` entries it proved gone (deleted key IDs, placeholders naming the user); the Azure CLI setup selects and verifies `SUBSCRIPTION_ID` before any lookup or creation.
- `discard-credential.sh` refuses a GCP key or Azure secret the config records for another member (or, for Azure, one labelled for another member), and keeps the plaintext with a non-zero exit when it cannot record an unrevoked credential. First-Time Setup and Add Team Member commit the SessionStart hook in the same commit as the credential and config, since the ignored plaintext cannot mark a fresh checkout as unfinished. `install.sh`, `update.sh` and the manual install resolve `main` to one commit and download every file from it.
- Add Team Member keeps `credentials.json` and the setup record until the SessionStart hook is ensured and committed (Step 4), as first-time setup does; `discard-credential.sh` stops with the unrecorded key IDs (keeping the plaintext) when it cannot record unknown AWS keys in `.cloud-config.json`.
- The Authenticate fallback's AWS cleanup also clears `AWS_PROFILE` and `AWS_SESSION_TOKEN`; AWS Grant Roles and the Add Team Member rollback check the bootstrap credentials' account first; GCP Grant Roles resolves the project from the config or setup record and refuses a conflicting `PROJECT_ID`; legacy offboarding reads the file-naming mode from the config, so an email starting with `aws.` or `gcp.` is parsed correctly.
- AWS first-time setup marks its record `ambiguous_group` when `create-group` fails for a chosen (not generated) group name that then exists, and the rollback leaves such a group alone unless `CONFIRM_GROUP=1`. The GCP setup rollback counts a 404 on deleting the service account as done only once it persists across retries. The GCP and Azure helpers that record ambiguous key or secret IDs stop with the IDs on screen if `.cloud-config.json` cannot be updated.
- `install.sh` swaps the downloaded release in with renames, like `update.sh` and the manual install. GCP setup treats a service account as absent after an ambiguous create only once it stays absent across retries (new accounts can take a minute or more to appear). The GCP setup rollback clears the `unrevoked` entries naming the deleted account's keys.
- The AWS setup rollback clears only the `unrevoked` entries it resolved (the key IDs it deleted, and placeholders naming the rolled-back user), keeping entries recorded for another account or an unknown owner. The Authenticate fallback logs out an earlier activation of the provider (and drops its persisted session settings) when decryption fails. The README's manual install swaps the staged copy in with renames, as `update.sh` does.
- `update.sh` puts the old installation back when interrupted between its two renames; the README's manual install downloads MANIFEST to a file before reading it, so a cut-off download fails instead of installing part of the skill; rotation's isolated verification stops if its config directory cannot be created; the AWS setup rollback clears the member's AWS `unrevoked` entries once the user and its keys are gone.
- AWS offboarding under pre-1.5 names (prefix `claude-agent`, where `.` and `@` both become `-`) requires the member's own credential file and refuses when another member's email maps to the same IAM user, unless `CONFIRM_USER=1`. The bootstrap command takes the MFA device ARN as `list-mfa-devices` prints it, and the policy examples use the account's partition, so China and GovCloud accounts work. The Azure rollbacks treat a missing application as gone only after it stays missing across retries (new Entra objects can read as missing for minutes).
- Rotation step 4 (AWS) checks the replacement against this member's user and the configured account, derived from the config and email rather than from the key's own owner, so a stale or wrong-account `credentials.json` is rejected even in a fresh shell. Azure setup records the service principal's object ID (and, on the CLI path, the app ID) as soon as they exist; both rollbacks remove role assignments by that object ID, which works after the principal is gone, and the CLI rollback finds the application by its recorded name when no ID was saved. The multi-provider hook revokes a GCP account it activated when a later step fails, and writes the ADC copy through a temp file.
- `update.sh` builds the complete new skill directory beside the installed one and swaps it in with two renames, so a failure mid-copy leaves the installed release unchanged; `discard-credential.sh` deletes the plaintext before exiting on an AWS account mismatch; the GCP rollback and role-grant snippets stop if their temp directory cannot be created; AWS Add Team Member marks its setup record `ambiguous` when a failed `create-user` leaves a user that an overlapping run may have created, and the rollback deletes such a user only with `CONFIRM_USER=1`.
- GCP hooks and manual activation revoke the earlier cached account after a successful activation when it differs from the configured service account (the account changed), instead of leaving it selectable.
- AWS identity checks (hooks and manual activation) compare the caller ARN without its partition, so `aws-cn` and `aws-us-gov` credentials are accepted; the Azure setup and Add Client Secret snippets stop if their private response directory cannot be created; uninstall skips the `settings.json` rewrite when the file or its `SessionStart` list is missing.
- AWS Add Team Member confirms the member's user name is free before recording it, so a rollback never deletes a user that already existed (another member's, or an earlier setup's). The Azure CLI-path rollback is a runnable block: it reads the subscription and app from the setup record, deletes every role assignment by ID, keeps the application while any remain, and treats an already-deleted application as done.
- `discard-credential.sh` deletes an AWS key (or, in member mode, a user) only when its owner is this member's user, from the setup record or derived from the email; a stale `credentials.json` or mistyped `CRED_ID` naming a teammate's key is refused. Rotation step 9 revokes only queued IDs (plus, with `COMPROMISE=1`, the key saved in step 3), never a shell's `OLD_KEY_ID`, so running it early in step 4 to free AWS key slots keeps the current key; it also marks the old key revoked only on the compromise path.
- The multi-provider hook also cleans up a provider removed from the config when an earlier activation left it behind (the GCP ADC key, persisted AWS exports, a cached az service-principal login); the README's manual install stops if the staging directory cannot be created and writes `.installed-files` as `install.sh` does; the Azure CLI rollback names the setup's subscription; the AWS prerequisites list `iam:GetGroup` and `iam:GetUser`, which the collision checks need.
- Workflows delete `.cloud-setup-pending.json` before `credentials.json`, so an interruption between the two never leaves a record that makes the next session roll back a committed identity; rotation step 4 (AWS) retries the key-owner lookup together with the STS check.
- Manual activation leaves no earlier identity active on failure: GCP notes the earlier account before replacing the key file and revokes it (and drops the persisted ADC export) when decryption, the account check, login or project selection fails; Azure stops and logs out when `az login` fails or the credential is for another app; AWS removes keys an earlier activation persisted when the identity check fails. AWS first-time setup keeps a user it may have created in the setup record (and rolls it back) unless AWS confirms it absent after a failed `create-user`. First-time setup keeps `credentials.json` and the setup record until the SessionStart hook is committed, so an interrupted run is recovered instead of leaving a repo without its hook.
- GCP hooks decrypt to a new file and replace the key file only once the key is verified, and the single-provider hook notes the earlier account before replacing the file, so a run whose new key fails to log in still revokes the earlier cached account; the GCP rollback keeps the account while its bindings remain; rotation step 9 revokes an AWS key only when it belongs to this member's user, and its rerun shortcut never applies while `revoked_early` is set; offboarding clears a member left with only `revoked_early`; AWS Add Team Member keeps its record when `create-user` fails unless the user is confirmed absent; AWS manual activation defines its naming helper; Azure setup cleanup removes the record after deleting the app, and the rollback treats an already-deleted app as done.
- AWS hook failure cleanup also unsets `AWS_PROFILE` and `AWS_SESSION_TOKEN`; GCP offboarding accepts a `KEY_ID` found from the key listing; every snippet that writes the setup record first makes sure `.gitignore` covers it; AWS setup confirms the group name is free and keeps its record after an ambiguous `create-group` failure; the phase check surfaces `unrevoked` entries; an AWS rotation that lost its key ID records unknown keys as ambiguous instead of deleting them.
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
- GCP keys are recorded per member in a non-secret `key_ids` map in `.cloud-config.json` (setup, Add Team Member, rotation; the recording snippets read the ID back from `credentials.json` or the encrypted file when run in a fresh shell), so offboarding can find a departed member's key; key deletion fails on HTTP errors and removes the member's `.enc` and map entry only after Google confirms.
- Rotation retries GCP replacement-key verification with backoff (new keys can take a minute to work) and, on final failure, deletes the unverified key and its plaintext.
- GCP Create Key and Key Management require the created or configured `SA_EMAIL` instead of falling back to `claude-agent@<project>`, which could be an unrelated existing account.
- Rotation takes the old GCP key ID from the committed `key_ids` entry when the shell has lost it, so `revoke_pending` is always written before that entry is replaced.
- Add Team Member encrypts to a temp file, verifies it and renames it into place; a failure or interruption revokes the new credential.
- GCP Create Service Account checks the account is absent first and deletes it after an ambiguous create failure.
- First-time setup adds the plaintext ignore rules before creating anything; adding Azure as a second provider records its `key_ids`.
- GCP and Azure offboarding also revoke the member's `rotating` ID and any `unrevoked` entries recorded for them, clearing each record once gone.
- The ambiguous-failure checks for GCP key and Azure secret creation capture curl's status with `if`/`else`, so they also run under `set -e`.
- Rotation step 6 (and step 8) resolve and require the passphrase themselves, so a fresh shell never re-encrypts with an empty passphrase.
- GCP Create Key lists the account's keys first and, if the create call fails ambiguously, revokes any key that appeared; Azure first-time cleanup finds a half-created app by its unique name; the first Azure secret is labelled with the member's email.
- First-time setup records the Azure secret's keyId in `key_ids`; rotation requires the new Azure keyId before changing records, and checks the AWS account before creating a replacement key.
- Manual GCP activation persists `GOOGLE_APPLICATION_CREDENTIALS` to `CLAUDE_ENV_FILE`; the README no longer calls AWS and Azure membership unlimited.
- `resolve_credentials_key` sets `KEY` without printing the passphrase; errors go to stderr.
- Add Client Secret treats any `addPassword` failure other than an HTTP rejection (curl exit 22), or an unreadable response, as possibly having created a secret, and revokes it before stopping.
- First-time setup stops on a failed encryption, deletes the plaintext and points to the provider's setup rollback.
- Azure records each member's secret `keyId` under `key_ids` (Add Client Secret, rotation), and offboarding removes the current and every pending secret, deleting the credential file only when none remain.
- The README's manual install downloads every file listed in `MANIFEST`, including `scripts/discard-credential.sh`.
- Rotation step 3 refuses to overwrite a `rotating` record left by an interrupted rotation (after step 6 the `.enc` already holds the replacement) and says where to resume.
- Azure first-time setup (CLI and REST) stores the initial secret's `keyId` in the credentials too.
- Passphrases go to OpenSSL through `printf '%s\n'` instead of `echo`, so a passphrase such as `-n` or `-e` is not swallowed as an option (normal passphrases produce the same bytes as before).
- Azure Graph responses, one of which holds the plaintext secret, are written to a private temp directory outside the repo that is removed on any exit.
- AWS offboarding stops before removing the member's credential file unless every IAM deletion succeeded, and then clears their pending entries.
- GCP Key Limits: keep one key slot free for rotation (9 members per service account).
- The discard-script call sites pass the bootstrap tokens and identifiers to the child process explicitly.
- Rotation saves the old key ID under `rotating[<email>]` in `.cloud-config.json` at step 3 for every provider; steps 8 and 9 are provider-generic, re-resolve the passphrase, file and identifiers themselves, and work through `revoke_pending` for AWS and Azure as for GCP. A failed rename in step 6 also revokes the replacement.
- Azure credentials carry the secret's `keyId`, so cleanup and rotation target the exact secret even when runs share a label; `discard-credential.sh` accepts a full GCP key resource name without any config.
- New `scripts/discard-credential.sh` revokes a credential the skill just created but cannot use (failed verification, encryption, or decoding) and deletes its plaintext. It re-resolves everything from `credentials.json`, the config and the provider, so it works from a fresh shell; Add Team Member, rotation (steps 5 and 6) and Create Key all use it. When revocation fails it records the non-secret ID under `unrevoked` in `.cloud-config.json`, to be committed, instead of an ignored local file.
- Rotation re-encryption failure (step 6) now revokes the replacement instead of leaving it and its plaintext behind; AWS verification reads the new key's owner from AWS, so it works without `IAM_USER` in the shell.
- A compromise-path revoke (step 9 before step 4) records `revoked_early`, so step 8 in a fresh shell knows the old key is gone. Step 9 and offboarding treat a 404 as already deleted and report a failed config update separately.
- Uninstall removes the identity (GCP service account and its bindings, AWS users/policies/group, Azure role assignments and app), not only its keys, revokes anything under `unrevoked`, and removes only the `cloud-auth.sh` SessionStart hook, keeping others.
- GCP Create Key deletes the new provider-side key when the response cannot be decoded or validated locally.
- Manual GCP activation clears `CLOUDSDK_AUTH_ACCESS_TOKEN`, and manual AWS activation clears `AWS_SESSION_TOKEN`/`AWS_PROFILE`, in the shell and in `CLAUDE_ENV_FILE`, as the hooks do.
- AWS setup rollback detaches managed and deletes inline group policies before deleting the group; the reformatted AWS `credentials.json` is written under `umask 077`.
- Rotation step 8 stops, instead of warning, when no old GCP key ID is known (configs older than `key_ids`), so the old key is never left unrecorded.
- Add Team Member's Azure rollback re-resolves the application and finds the new secret by its member label when run in a fresh shell.
- `revoke_pending` is a list per member: a second rotation adds to it instead of overwriting a still-live key; rotation step 9 deletes every listed key (and, with `COMPROMISE=1` before the replacement exists, the current `key_ids` key, even from a fresh shell); offboarding deletes the current and all pending keys and removes the `.enc` file only when all are gone.
- AWS setup and Add Team Member check with `get-caller-identity` that the bootstrap credentials belong to the approved account before any IAM change.
- Azure setup uses the REST path with the pasted tokens unless the sandbox's `az` is itself signed in; the CLI snippets check `az account show` and stop otherwise.
- The multi-provider hook persists the Azure CLI location to `CLAUDE_ENV_FILE`.
- Add Team Member's AWS rollback on failed encryption runs inline (finding the user from the new access key).
- GCP offboarding resolves the project and service account in its own block; after an early (compromise-path) revoke, rotation no longer re-queues the deleted key in `revoke_pending`.
- Add Team Member revokes the new GCP key, Azure secret, or AWS user when encryption fails, and always removes the plaintext.
- All hook templates `cd` to `$CLAUDE_PROJECT_DIR` first, so a session started in a subdirectory still authenticates.
- AWS and Azure offboarding name the provider-prefixed credential file in multi-provider repos.
- `install.sh` records the installed file list in `.installed-files`; `update.sh` removes files the previous release installed that the new one no longer ships.
- Rotation keeps the old GCP key ID in `revoke_pending` until Google confirms its deletion, and its GCP verify and revoke snippets resolve the project and service account from config themselves; AWS verification retries with backoff and deletes the new access key on final failure; Azure verification failure removes the new secret by the `keyId` that Add Client Secret now keeps.
- Config lookups use top-level fields only when the top-level `provider` matches, so while a second provider is provisioned the snippets never pick up the first provider's project or identity; the migration steps say which values to set.
- AWS Add Team Member has a standalone rollback snippet for failures in a later shell. AWS Add Team Member rolls back the user, membership, and keys it created on failure; the prerequisite lists include the IAM actions rollback needs.
- Azure CLI setup writes `credentials.json` under `umask 077`; the role-grant snippets read the app id from the `providers[]` entry in multi-provider configs.
- Azure Add Team Member validates the tenant and resolves the application before `addPassword`, fails on HTTP errors, and requires `secretText`; Secret Management resolves the application itself and deletes a member's `.enc` only after `removePassword` returns 204.
- Key Limits no longer claims unlimited client secrets: entries count against a shared per-application manifest limit, so add-member lists existing secrets and prunes first.
- Azure service-principal names are a sanitized repo slug plus a random per-run suffix: safe inside JSON and OData strings, and concurrent setups can no longer race to the same name (which `create-for-rbac` would reuse).
- Azure REST setup documents a "Rollback a Failed Setup" step (delete the half-created application and the local plaintext) for failures after the creation block, whose trap cannot span later snippets; first-time setup says to undo a created identity before retrying on every provider.
- GCP service-account creation fails on any HTTP error (409 = the account already exists) instead of continuing to grant roles and create keys for a pre-existing account.
- Uninstall removes the `.gitignore` rules setup actually adds (`/credentials.json`, `/credentials_clean.json`), plus the pre-1.5 forms.
- Setup's `.gitignore` entries are anchored to the repo root (`/credentials.json`, `/credentials_clean.json`); the repo-relative `/tmp/` entry, which never covered the system `/tmp`, is gone.
- AWS: when the pending record cannot be marked as unconfirmed after a lost `create-group` (chosen name) or member `create-user` response, setup removes the record instead of leaving one a rollback would act on, and tells the user to resolve the group or user by hand. AWS member removal stops if it cannot clear a deleted key's `unrevoked` entry, since a retry no longer sees that key.
- Azure CLI rollback selects and verifies the setup's recorded subscription before looking anything up, so a CLI signed in to another tenant cannot make it report "nothing was created" and delete the record while the application stays live.
- A failed encryption in first-time setup removes only its temp file and the plaintext, never an existing `.enc` file of the same name, which the staged write leaves untouched until the final rename.
- `discard-credential.sh` (Azure) uses a supplied or inherited `OBJECT_ID` only after confirming it resolves to the configured application's `appId`; otherwise it looks the application up by `APP_ID`, so the label fallback never removes a secret from an unrelated application.
- GCP activation (SessionStart hook template, multi-provider hook, Activate snippet) also checks the decrypted key's `private_key_id` against `key_ids`: a key recorded for another member, or one that differs from the member's own entry outside an open rotation, is not activated.
- `discard-credential.sh` (GCP) counts a 404 as "already deleted" only once it persists across retries, since a key created moments earlier can read as missing for a minute or more.
- Uninstall matches the `## Cloud credentials` heading case-insensitively.

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
