#!/bin/bash
# Check for updates to cloud-bootstrap and optionally apply them.
# Usage: curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/update.sh | bash
#   or run from a repo that has cloud-bootstrap installed:
#     bash .claude/skills/cloud-bootstrap/update.sh   (if bundled)
set -e

REPO_URL="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main"
DEST=".claude/skills/cloud-bootstrap"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not inside a git repository. Run this from your repo root." >&2
  exit 1
fi

# Determine installed version
INSTALLED_VERSION=""
if [ -f "$DEST/SKILL.md" ]; then
  INSTALLED_VERSION=$(grep -m1 '^version:' "$DEST/SKILL.md" 2>/dev/null | awk '{print $2}')
fi

if [ -z "$INSTALLED_VERSION" ]; then
  echo "cloud-bootstrap is not installed or has no version info."
  echo "Run the installer instead:"
  echo "  curl -sSL ${REPO_URL/raw.githubusercontent.com\/ipeirotis\/cloud-bootstrap\/main/raw.githubusercontent.com\/ipeirotis\/cloud-bootstrap\/main}/install.sh | bash"
  exit 1
fi

echo "Installed version: $INSTALLED_VERSION"

# Fetch latest version
LATEST_VERSION=$(curl -sSL "$REPO_URL/VERSION" | tr -d '[:space:]')
if [ -z "$LATEST_VERSION" ]; then
  echo "ERROR: Could not fetch latest version." >&2
  exit 1
fi

echo "Latest version:    $LATEST_VERSION"

if [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
  echo ""
  echo "You are up to date."
  exit 0
fi

echo ""
echo "--- Changelog (new entries since $INSTALLED_VERSION) ---"
echo ""

# Fetch and display changelog, showing only entries newer than the installed version
CHANGELOG=$(curl -sSL "$REPO_URL/CHANGELOG.md")
echo "$CHANGELOG" | awk -v installed="$INSTALLED_VERSION" '
  /^## \[/ {
    # Extract version from heading like "## [1.2.0] - 2026-04-01"
    match($0, /\[([0-9]+\.[0-9]+\.[0-9]+)\]/, arr)
    if (arr[1] == installed) { found_installed = 1; next }
    if (!found_installed) { print; next }
  }
  !found_installed { print }
'

echo ""
echo "--- End of changelog ---"
echo ""

# If running interactively, ask for confirmation
if [ -t 0 ]; then
  printf "Update from %s to %s? [y/N] " "$INSTALLED_VERSION" "$LATEST_VERSION"
  read -r REPLY
  if [ "$REPLY" != "y" ] && [ "$REPLY" != "Y" ]; then
    echo "Update cancelled."
    exit 0
  fi
fi

# Perform update
echo "Updating..."
mkdir -p "$DEST/references"

for FILE in SKILL.md references/gcp.md references/aws.md references/azure.md; do
  curl -sSL "$REPO_URL/$FILE" -o "$DEST/$FILE"
done

git add "$DEST"
git commit -m "Update cloud-bootstrap skill to $LATEST_VERSION"

echo ""
echo "Updated cloud-bootstrap from $INSTALLED_VERSION to $LATEST_VERSION."
