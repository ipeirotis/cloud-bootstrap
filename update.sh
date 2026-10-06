#!/bin/bash
# Check for updates to cloud-bootstrap and optionally apply them.
# Usage: curl -sSL https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main/update.sh | bash
#   Non-interactive (no terminal available): ... | bash -s -- --yes
# Always run it this way, so the newest updater and file list are used.
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/main"
# Read the version, changelog, manifest and files from one commit: main can
# move between requests, and a mix of two releases would install silently
SHA=$(curl -fsSL -H 'Accept: application/vnd.github.sha' https://api.github.com/repos/ipeirotis/cloud-bootstrap/commits/main)
printf '%s' "$SHA" | grep -qxE '[0-9a-f]{40}' || { echo "ERROR: could not resolve the current release commit." >&2; exit 1; }
SRC="https://raw.githubusercontent.com/ipeirotis/cloud-bootstrap/$SHA"
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
LATEST_VERSION=$(curl -fsSL "$SRC/VERSION" | tr -d '[:space:]')
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
CHANGELOG=$(curl -fsSL "$SRC/CHANGELOG.md")
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
curl -fsSL "$SRC/MANIFEST" -o "$TMP/MANIFEST"
FILES=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TMP/MANIFEST")
for FILE in $FILES; do
  mkdir -p "$TMP/files/$(dirname "$FILE")"
  curl -fsSL "$SRC/$FILE" -o "$TMP/files/$FILE"
done
mkdir -p "$DEST"
# Build the complete new skill directory next to the installed one, then swap
# it in with two renames: a failure while building (a full disk, an unwritable
# file) leaves the installed release untouched instead of a mix of both
PARENT=$(dirname "$DEST"); NAME=$(basename "$DEST")
NEW=$(mktemp -d "$PARENT/.$NAME.new.XXXXXX")
OLD_DIR="$PARENT/.$NAME.old.$$"
# On any exit, including an interruption between the two renames below, put
# the old installation back if the new one is not in place
trap 'rm -rf "$TMP" "$NEW"; if [ -d "$OLD_DIR" ] && [ ! -e "$DEST" ]; then mv "$OLD_DIR" "$DEST"; fi' EXIT
trap 'exit 1' INT TERM HUP
cp -R "$DEST/." "$NEW/"
# Remove files the previous release installed that this release no longer
# ships, so a dropped or renamed workflow does not linger. Only paths listed
# in the recorded file list are touched; installs older than that list have
# none, and nothing is removed for them.
if [ -f "$NEW/.installed-files" ]; then
  while IFS= read -r OLD; do
    case "$OLD" in ''|/*|*..*) continue ;; esac
    printf '%s\n' $FILES | grep -qxF -- "$OLD" || rm -f -- "$NEW/$OLD"
  done < "$NEW/.installed-files"
  find "$NEW" -mindepth 1 -type d -empty -delete
fi
cp -R "$TMP/files/." "$NEW/"
printf '%s\n' $FILES > "$NEW/.installed-files"
chmod 755 "$NEW"   # mktemp -d creates it 700; match a normal directory
mv "$DEST" "$OLD_DIR"
if ! mv "$NEW" "$DEST"; then
  mv "$OLD_DIR" "$DEST"
  echo "ERROR: could not move the new release into place; $DEST is unchanged."
  exit 1
fi
rm -rf "$OLD_DIR"

# Commit only the skill directory, leaving any other staged changes alone.
git add -- "$DEST"
if git diff --cached --quiet -- "$DEST"; then
  echo "No changes to commit in $DEST."
else
  git commit -m "Update cloud-bootstrap skill to $LATEST_VERSION" -- "$DEST"
fi

echo ""
echo "Updated cloud-bootstrap from $INSTALLED_VERSION to $LATEST_VERSION."
