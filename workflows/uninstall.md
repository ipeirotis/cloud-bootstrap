# Uninstall

To completely remove cloud-bootstrap from a repo:

1. **Revoke provider-side credentials FIRST**, while `.cloud-config.json` still
   exists — it holds the project/subscription, service account / app / group
   name, and provider type needed to identify what to delete. Removing the local
   metadata first can strand live cloud credentials.
   Remove the identity itself, not just its keys: deleting keys or secrets stops those credentials but leaves the principal and its role grants, which other credentials or impersonation could still use.
   - **GCP:** Remove the service account's project IAM bindings (each approved role, the reverse of "Grant Roles"), then delete the service account, which also deletes all its keys.
   - **AWS:** For each member user, delete its access keys, remove it from the group, and delete it; then detach the group's managed policies, delete its inline policies, and delete the group.
   - **Azure:** Delete the role assignments for the service principal, then the app registration, which removes its service principal and client secrets.
   - **Also** revoke anything listed under `unrevoked` in `.cloud-config.json` (credentials an earlier run could not revoke).

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
   - In `.claude/settings.json`, remove only the hook whose command runs `cloud-auth.sh`; keep any other SessionStart hooks (drop a matcher group or `SessionStart` itself only if nothing is left in it, and delete the file only if nothing else remains):
     ```bash
     # Nothing to do when the file or its SessionStart list is missing (an
     # interrupted setup, a hook removed by hand): uninstall must keep going
     [ ! -f .claude/settings.json ] || { jq 'if (.hooks.SessionStart | type) == "array" then
           .hooks.SessionStart |= (map(.hooks |= ((. // []) | map(select((.command // "") | contains("cloud-auth.sh") | not))))
             | map(select(.hooks | length > 0)))
           | (if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end)
           | (if .hooks == {} then del(.hooks) else . end)
         else . end' .claude/settings.json > .claude/settings.json.tmp \
       && mv .claude/settings.json.tmp .claude/settings.json; }
     ```
5. **Delete any plaintext an interrupted run left, then clean up `.gitignore`:** these files are ignored only until the next step removes the rules, and a later `git add -A` would commit a live key. (Step 1's revocation covers the credentials in them; for one not listed anywhere, run "Recovering an Interrupted Run" in SKILL.md first.)
   ```bash
   rm -f credentials.json credentials_clean.json .cloud-setup-pending.json .cloud-credentials.*.tmp.*
   ```
   Then remove the rules setup added: the `# Cloud -- never commit plaintext credentials` comment, `/credentials.json`, `/credentials_clean.json`, and `/.cloud-setup-pending.json`. Older setups wrote `credentials.json`, `credentials_clean.json`, and `/tmp/` instead; remove those if present. Check `git status --porcelain --ignored` shows none of these files before committing.
6. **Remove the `## Cloud Credentials` section from the repo's agent-instructions file(s)** — `CLAUDE.md`, `AGENTS.md`, or both; check each (`grep -n '^## Cloud Credentials' CLAUDE.md AGENTS.md`) and delete that section, up to the next `## ` heading, wherever it appears.
7. **Commit all changes.**

**Important:** This does not remove the skill files from `.claude/skills/cloud-bootstrap/`. Those can be kept (no secrets) or removed separately.
