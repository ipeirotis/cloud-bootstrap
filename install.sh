#!/bin/bash
# Install cloud-bootstrap skill into the current repo.
# Usage: curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/install.sh | bash
set -euo pipefail

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not inside a git repository. Run this from your repo root." >&2
  exit 1
fi

BASE_URL="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main"
# Fetch every file from one commit: main can move between requests, and a mix
# of two releases would otherwise install without any error
# Resolved with git, not GitHub's REST API, whose unauthenticated quota is
# shared by everyone behind the same IP address
SHA=$(git ls-remote https://github.com/ipeirotis/cloud-bootstrap.git refs/heads/main | cut -f1)
printf '%s' "$SHA" | grep -qxE '[0-9a-f]{40}' || { echo "ERROR: could not resolve the current release commit." >&2; exit 1; }
SRC="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/$SHA"
DEST=".claude/skills/cloud-bootstrap"

# Download everything into a temp dir first, failing on any HTTP error, so a
# missing file or a 4xx/5xx body never lands in (or half-replaces) the skill.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$SRC/MANIFEST" -o "$TMP/MANIFEST"
FILES=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TMP/MANIFEST")
# A manifest that names a path outside the skill, or leaves out the files every
# release needs, is refused before anything is downloaded or replaced
for FILE in $FILES; do
  case "$FILE" in /*|*..*) echo "ERROR: MANIFEST lists an unsafe path ($FILE); nothing changed." >&2; exit 1 ;; esac
done
for REQ in VERSION SKILL.md; do
  printf '%s\n' $FILES | grep -qxF "$REQ" \
    || { echo "ERROR: MANIFEST does not list $REQ; nothing changed." >&2; exit 1; }
done
for FILE in $FILES; do
  mkdir -p "$TMP/files/$(dirname "$FILE")"
  curl -fsSL "$SRC/$FILE" -o "$TMP/files/$FILE"
done
# Every file SKILL.md sends the agent to, and the revocation helper the
# workflows call, must be in the release: a missing one would surface only
# mid-workflow, possibly with a live credential to clean up
REQUIRED="VERSION SKILL.md scripts/discard-credential.sh $(grep -oE '(workflows|references|scripts)/[A-Za-z0-9_-]+\.(md|sh)' "$TMP/files/SKILL.md" | sort -u)"
for REQ in $REQUIRED; do
  [ -s "$TMP/files/$REQ" ] || { echo "ERROR: the release lacks $REQ (missing from MANIFEST or empty); nothing changed." >&2; exit 1; }
done

# Record which files this release installed, so update.sh can remove the ones
# a later release drops
printf '%s\n' $FILES > "$TMP/files/.installed-files"
# Swap the complete release in with renames (as update.sh does): a failure
# leaves an existing installation untouched instead of a mix of two releases
PARENT=$(dirname "$DEST"); NAME=$(basename "$DEST")
mkdir -p "$PARENT"
NEW=$(mktemp -d "$PARENT/.$NAME.new.XXXXXX")
OLD_DIR="$PARENT/.$NAME.old.$$"
trap 'rm -rf "$TMP" "$NEW"; if [ -d "$OLD_DIR" ] && [ ! -e "$DEST" ]; then mv "$OLD_DIR" "$DEST"; fi' EXIT
trap 'exit 1' INT TERM HUP
cp -R "$TMP/files/." "$NEW/"
chmod 755 "$NEW"   # mktemp -d creates it 700; match a normal directory
if [ -e "$DEST" ]; then mv "$DEST" "$OLD_DIR"; fi
mv "$NEW" "$DEST"
rm -rf "$OLD_DIR"

INSTALLED_VERSION=$(tr -d '[:space:]' < "$DEST/VERSION")
INSTALLED_VERSION="${INSTALLED_VERSION:-unknown}"

# Commit only the skill directory: anything the caller already had staged
# stays staged and out of this commit.
git add -- "$DEST"
if git diff --cached --quiet -- "$DEST"; then
  echo "No changes to commit in $DEST."
else
  git commit -m "Add cloud-bootstrap skill v${INSTALLED_VERSION}" -- "$DEST"
fi

echo "cloud-bootstrap v${INSTALLED_VERSION} installed in $DEST"
echo ""
echo "Set your encryption passphrase as an environment variable in Claude Code on the Web:"
echo "  CLOUD_CREDENTIALS_KEY or GCP_CREDENTIALS_KEY / AWS_CREDENTIALS_KEY / AZURE_CREDENTIALS_KEY"
echo ""
echo "To check for updates later, run:"
echo "  curl -sSL ${BASE_URL}/update.sh | bash"
