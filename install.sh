#!/bin/bash
# Install cloud-bootstrap skill into the current repo.
# Usage: curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/install.sh | bash
set -euo pipefail

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not inside a git repository. Run this from your repo root." >&2
  exit 1
fi

BASE_URL="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main"
DEST=".claude/skills/cloud-bootstrap"

# Download everything into a temp dir first, failing on any HTTP error, so a
# missing file or a 4xx/5xx body never lands in (or half-replaces) the skill.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$BASE_URL/MANIFEST" -o "$TMP/MANIFEST"
FILES=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TMP/MANIFEST")
for FILE in $FILES; do
  mkdir -p "$TMP/files/$(dirname "$FILE")"
  curl -fsSL "$BASE_URL/$FILE" -o "$TMP/files/$FILE"
done

mkdir -p "$DEST"
cp -R "$TMP/files/." "$DEST/"

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
