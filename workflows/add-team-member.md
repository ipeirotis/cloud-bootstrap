# Add Team Member

This flow runs when `.cloud-config.json` exists (the service account is already set up) but the current user has no encrypted credentials file yet.

## Step 1: Read Existing Config

Read `.cloud-config.json` to get the provider, project ID, and service account identity. Read the corresponding provider reference file.

## Step 2: Explain and Get Bootstrap Token

Tell the user:

```
This repo already has cloud access configured:
  Provider: <provider>
  Project: <project_id>
  Service account: <service_account>
  Roles: <roles>

I need to create a new key for this service account, encrypted with your
personal passphrase. This means you won't need anyone else's password.

Please run this on your local machine and paste the result:
  <bootstrap token command from provider reference>
```

Tell them the specific permission needed from the provider reference file (see "Team Member Prerequisites" in each reference).

## Step 3: Create New Key and Encrypt

Using the bootstrap token and provider-specific commands:

0. **Resolve the encryption key for the current user first** (SKILL.md), before creating anything on the provider side. If it is missing, stop and ask the user to set it; never create a key you cannot encrypt.
1. Create the new member's credential:
   - **GCP / Azure:** create a **new key** (GCP) or client secret (Azure) for the **existing** service account or app (do NOT create a new one). See the "Add Key for Existing Service Account" / "Add Client Secret" section in the provider reference.
   - **AWS:** the configured `service_account` is the shared IAM **group**, and access keys belong to users, not groups. Create a **new IAM user for this member in the existing group**, then its access key, following "Add Team Member: Create New User in Existing Group" in `references/aws.md`.
2. Use the encryption key resolved in step 0.
3. Encrypt with the user's email in the filename. Use the multi-provider naming convention if the config has a `providers` array:
   ```bash
   USER_EMAIL=$(git config user.email)
   if jq -e '.providers' .cloud-config.json >/dev/null 2>&1; then
     # PROVIDER must already be set from Step 1 — validate but do not overwrite
     if [ -z "$PROVIDER" ] || [ "$PROVIDER" = "null" ]; then
       echo "ERROR: PROVIDER is not set — determine it from .cloud-config.json in Step 1."
       exit 1
     fi
     ENC_FILE=".cloud-credentials.${PROVIDER}.${USER_EMAIL}.enc"
   else
     PROVIDER=$(jq -r .provider .cloud-config.json)
     ENC_FILE=".cloud-credentials.${USER_EMAIL}.enc"
   fi
   # On any failure or interruption before the encrypted file is in place, the
   # provider-side credential is live but unusable: revoke it (for AWS, with the
   # member's new IAM user) and delete the plaintext. If revocation fails, the
   # script records the ID under "unrevoked" in .cloud-config.json; commit that.
   ENC_EXISTED=""; [ -e "$ENC_FILE" ] && ENC_EXISTED=1
   discard_new() {
     rm -f "${TMP_ENC:-}"
     # A signal right after the rename must not leave a credential file for a
     # key this handler is about to revoke (the next session would try it)
     [ -n "$ENC_EXISTED" ] || rm -f "$ENC_FILE"
     echo "ERROR: encryption did not complete; revoking the new $PROVIDER credential."
     TOKEN="${TOKEN:-}" GRAPH_TOKEN="${GRAPH_TOKEN:-}" PROJECT_ID="${PROJECT_ID:-}" SA_EMAIL="${SA_EMAIL:-}" \
         bash .claude/skills/cloud-bootstrap/scripts/discard-credential.sh "$PROVIDER" member
     exit 1
   }
   trap discard_new INT TERM
   # Encrypt to a private temp file, prove it decrypts to the credential, and
   # only then move it into place in one rename: a truncated file never appears
   # under the final name (which would make the next session try Authenticate).
   TMP_ENC=$(umask 077 && mktemp "${ENC_FILE}.tmp.XXXXXX") || discard_new
   if printf '%s\n' "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass stdin \
        -in credentials.json -out "$TMP_ENC" \
      && printf '%s\n' "$KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$TMP_ENC" \
        | cmp -s - credentials.json \
      && mv -f "$TMP_ENC" "$ENC_FILE"; then
     trap - INT TERM
   else
     discard_new
   fi
   ```
   **Note:** In multi-provider mode, `PROVIDER` must be set to the provider being onboarded (e.g., `gcp`, `aws`, `azure`) before running this snippet. Step 1 determines the provider from `.cloud-config.json`.
4. **GCP:** record the new key's ID under `key_ids` in `.cloud-config.json` ("Record the key's owner" in `references/gcp.md`), so the key can be found when this member leaves. (Azure's "Add Client Secret" snippet records the secret's `keyId` there itself.) Run it before the next step: it reads the ID from `credentials.json` (or, failing that, from the encrypted file).
5. Commit the new encrypted credentials file and `.cloud-config.json` (it now holds this member's `key_ids` entry for GCP or Azure, and any `unrevoked` record).
6. **Keep `credentials.json` (and, for AWS, `.cloud-setup-pending.json`) until Step 4 is done.** Until then their presence marks the onboarding as unfinished for the next session ("Recovering an Interrupted Run" in SKILL.md), so a missing SessionStart hook is still added if this run stops.

## Step 4: Ensure SessionStart Hook Exists

Check if `.claude/settings.json` already contains a SessionStart hook for the provider's CLI. If not, add one following the "SessionStart Hook" instructions in the provider's reference file. Commit `.claude/hooks/cloud-auth.sh` and `.claude/settings.json` if they were created or modified.

**Only after the hook is in place and committed, delete the recovery state:**
```bash
# The marker goes first: a marker left without the plaintext would make
# the next session roll back the identity this run just committed
rm -f .cloud-setup-pending.json
rm -f credentials.json
```
(`.cloud-setup-pending.json` exists only for AWS, where the snippet records the new member's IAM user before creating it.)

## Step 5: Done

The bootstrap token is now spent. The user can now authenticate in future sessions using their own passphrase.
