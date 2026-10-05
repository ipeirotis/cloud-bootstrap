# Uninstall

To completely remove cloud-bootstrap from a repo:

1. **Revoke provider-side credentials FIRST**, while `.cloud-config.json` still
   exists — it holds the project/subscription, service account / app / group
   name, and provider type needed to identify what to delete. Removing the local
   metadata first can strand live cloud credentials.
   - **GCP:** Delete the service account or its keys
   - **AWS:** Delete the IAM user(s) and group
   - **Azure:** Delete the app registration or its client secrets

   Ask the user for a bootstrap token to perform these provider-side deletions, or instruct them to do it manually via the cloud console. (If you must defer revocation, first copy the identifiers out of `.cloud-config.json` so they aren't lost.)
2. **Remove encrypted credential files:**
   ```bash
   rm -f .cloud-credentials.*.enc
   ```
3. **Remove config:**
   ```bash
   rm -f .cloud-config.json
   ```
4. **Remove the SessionStart hook:**
   - Delete `.claude/hooks/cloud-auth.sh`
   - Remove the `SessionStart` entry from `.claude/settings.json` (or delete the file if the hook was the only content)
5. **Clean up `.gitignore`:** Remove the rules setup added: the `# Cloud -- never commit plaintext credentials` comment, `/credentials.json`, and `/credentials_clean.json`. Older setups wrote `credentials.json`, `credentials_clean.json`, and `/tmp/` instead; remove those if present.
6. **Remove the `## Cloud Credentials` section from the repo's agent-instructions file(s)** — `CLAUDE.md`, `AGENTS.md`, or both; check each (`grep -n '^## Cloud Credentials' CLAUDE.md AGENTS.md`) and delete that section, up to the next `## ` heading, wherever it appears.
7. **Commit all changes.**

**Important:** This does not remove the skill files from `.claude/skills/cloud-bootstrap/`. Those can be kept (no secrets) or removed separately.
