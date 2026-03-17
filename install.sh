#!/bin/bash
# Install cloud-bootstrap skill into the current repo.
# Usage: curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/install.sh | bash
set -e

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not inside a git repository. Run this from your repo root." >&2
  exit 1
fi

BASE_URL="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main"
DEST=".claude/skills/cloud-bootstrap"

mkdir -p "$DEST/references"

for FILE in SKILL.md references/gcp.md references/aws.md references/azure.md; do
  curl -sSL "$BASE_URL/$FILE" -o "$DEST/$FILE"
done

# Read the installed version from the SKILL.md frontmatter
INSTALLED_VERSION=$(grep -m1 '^version:' "$DEST/SKILL.md" 2>/dev/null | awk '{print $2}')
INSTALLED_VERSION="${INSTALLED_VERSION:-unknown}"

git add "$DEST"
git commit -m "Add cloud-bootstrap skill v${INSTALLED_VERSION}"

echo "cloud-bootstrap v${INSTALLED_VERSION} installed in $DEST"
echo ""
echo "Set your encryption passphrase as an environment variable in Claude Code on the Web:"
echo "  CLOUD_CREDENTIALS_KEY or GCP_CREDENTIALS_KEY / AWS_CREDENTIALS_KEY / AZURE_CREDENTIALS_KEY"
echo ""
echo "To check for updates later, run:"
echo "  curl -sSL ${BASE_URL}/update.sh | bash"
