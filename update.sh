#!/bin/bash
# Check for updates to cloud-bootstrap and optionally apply them.
# Usage: curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/update.sh | bash
#   Non-interactive (no terminal available): ... | bash -s -- --yes
# Always run it this way, so the newest updater and file list are used.
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main"
DEST=".claude/skills/cloud-bootstrap"
ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not inside a git repository. Run this from your repo root." >&2
  exit 1
fi

# Determine installed version
INSTALLED_VERSION=""
if [ -f "$DEST/VERSION" ]; then
  INSTALLED_VERSION=$(tr -d '[:space:]' < "$DEST/VERSION")
elif [ -f "$DEST/SKILL.md" ]; then
  INSTALLED_VERSION=$(grep -m1 '^version:' "$DEST/SKILL.md" 2>/dev/null | awk '{print $2}' || true)
fi

if [ -z "$INSTALLED_VERSION" ]; then
  echo "cloud-bootstrap is not installed or has no version info."
  echo "Run the installer instead:"
  echo "  curl -sSL $REPO_URL/install.sh | bash"
  exit 1
fi

echo "Installed version: $INSTALLED_VERSION"

# Fetch latest version (fails on HTTP errors instead of reading an error body)
LATEST_VERSION=$(curl -fsSL "$REPO_URL/VERSION" | tr -d '[:space:]')
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
CHANGELOG=$(curl -fsSL "$REPO_URL/CHANGELOG.md")
echo "$CHANGELOG" | awk -v installed="$INSTALLED_VERSION" '
  /^## \[/ {
    # Extract version from heading like "## [1.2.0] - 2026-04-01"
    ver = $0
    gsub(/.*\[/, "", ver)
    gsub(/\].*/, "", ver)
    if (ver == installed) { found_installed = 1; next }
    if (!found_installed) { print; next }
  }
  !found_installed { print }
'

echo ""
echo "--- End of changelog ---"
echo ""

# Confirm before changing anything. Under `curl ... | bash`, stdin is the
# script itself, so read the answer from the terminal; with no terminal at
# all, require an explicit --yes rather than updating silently.
if [ "$ASSUME_YES" -ne 1 ]; then
  if { : < /dev/tty; } 2>/dev/null; then
    printf "Update from %s to %s? [y/N] " "$INSTALLED_VERSION" "$LATEST_VERSION" > /dev/tty
    read -r REPLY < /dev/tty
    if [ "$REPLY" != "y" ] && [ "$REPLY" != "Y" ]; then
      echo "Update cancelled."
      exit 0
    fi
  else
    echo "No terminal to confirm on. Re-run with --yes to apply:"
    echo "  curl -sSL $REPO_URL/update.sh | bash -s -- --yes"
    exit 1
  fi
fi

# Download the new release's full file list into a temp dir first; replace the
# installed files only after every download succeeded.
echo "Updating..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$REPO_URL/MANIFEST" -o "$TMP/MANIFEST"
FILES=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TMP/MANIFEST")
for FILE in $FILES; do
  mkdir -p "$TMP/files/$(dirname "$FILE")"
  curl -fsSL "$REPO_URL/$FILE" -o "$TMP/files/$FILE"
done
mkdir -p "$DEST"
# Remove files the previous release installed that this release no longer
# ships, so a dropped or renamed workflow does not linger. Only paths listed
# in the recorded file list are touched; installs older than that list have
# none, and nothing is removed for them.
if [ -f "$DEST/.installed-files" ]; then
  while IFS= read -r OLD; do
    case "$OLD" in ''|/*|*..*) continue ;; esac
    printf '%s\n' $FILES | grep -qxF -- "$OLD" || rm -f -- "$DEST/$OLD"
  done < "$DEST/.installed-files"
  find "$DEST" -mindepth 1 -type d -empty -delete
fi
cp -R "$TMP/files/." "$DEST/"
printf '%s\n' $FILES > "$DEST/.installed-files"

# Commit only the skill directory, leaving any other staged changes alone.
git add -- "$DEST"
if git diff --cached --quiet -- "$DEST"; then
  echo "No changes to commit in $DEST."
else
  git commit -m "Update cloud-bootstrap skill to $LATEST_VERSION" -- "$DEST"
fi

echo ""
echo "Updated cloud-bootstrap from $INSTALLED_VERSION to $LATEST_VERSION."
