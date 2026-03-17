#!/bin/bash
# Install cloud-bootstrap skill into the current repo.
# Usage: curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/install.sh | bash
set -e

BASE_URL="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main"
DEST=".claude/skills/cloud-bootstrap"

mkdir -p "$DEST/references"

for FILE in SKILL.md references/gcp.md references/aws.md references/azure.md; do
  curl -sSL "$BASE_URL/$FILE" -o "$DEST/$FILE"
done

git add "$DEST"
git commit -m "Add cloud-bootstrap skill"

echo "cloud-bootstrap skill installed in $DEST"
echo "Set your encryption passphrase as an environment variable in Claude Code on the Web:"
echo "  CLOUD_CREDENTIALS_KEY or GCP_CREDENTIALS_KEY / AWS_CREDENTIALS_KEY / AZURE_CREDENTIALS_KEY"
