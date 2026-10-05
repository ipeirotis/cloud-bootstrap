# Permission Escalation

If any cloud API call fails with 403, "access denied", or equivalent:

1. **Stop.** Do not retry or attempt workarounds.
2. Tell the user:
   - The exact error message
   - The specific role or permission needed
   - Why it is needed
3. Ask the user to:
   - Grant the role to the service account
   - Provide a new bootstrap token if IAM changes require it
4. After the user confirms, retry the operation.
5. Update the `.cloud-config.json` roles array and the Cloud Credentials section of the repo's agent-instructions file to reflect the new role: `CLAUDE.md`, or `AGENTS.md` when that is the file the repo uses (the same choice as First-Time Setup, Step 7).

**Never modify IAM policies yourself.**
