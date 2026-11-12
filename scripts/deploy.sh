#!/usr/bin/env bash
# Releases NoteIt: bumps the version, builds the zip, pushes main and a tag,
# creates the GitHub release, and updates the cask in its-ash/homebrew-tap.
#
#   make deploy           # next patch version, e.g. 1.0.0 -> 1.0.1
#   make deploy V=1.1.0   # a version you choose
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="its-ash/noteit"
TAP_REPO="its-ash/homebrew-tap"
CASK="Casks/noteit.rb"
PLIST="Info.plist"

say() { printf '\033[1m→ %s\033[0m\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

# --- Check everything before changing anything ---
command -v gh >/dev/null || die "needs the GitHub CLI: brew install gh"
gh auth status >/dev/null 2>&1 || die "sign in to GitHub first: gh auth login"
[[ "$(git branch --show-current)" == "main" ]] || die "switch to the main branch first"
git fetch -q origin main
[[ -z "$(git rev-list HEAD..origin/main)" ]] || die "main is behind origin/main; pull first"

CUR=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
NEW="${1:-$(echo "$CUR" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3, not '$NEW'"
TAG="v$NEW"
ZIP="build/NoteIt-$NEW-macos.zip"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists here"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on GitHub"

# --- Bump and build. Until the commit, a failure puts Info.plist back. ---
committed=0
restore() { [[ $committed == 1 ]] || git checkout -q -- "$PLIST"; }
trap restore EXIT

say "Version $CUR → $NEW (build $((BUILD + 1)))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"

say "Running tests"
swift test

say "Building $ZIP"
make zip
[[ -f "$ZIP" ]] || die "build finished without $ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')

# --- Publish NoteIt ---
say "Committing and pushing main with tag $TAG"
git add -A
git commit -q -m "Release $TAG"
committed=1
git tag "$TAG"
git push -q origin main "$TAG"

say "Creating the GitHub release"
gh release create "$TAG" "$ZIP" -R "$REPO" \
  --title "NoteIt $NEW" \
  --notes "Install or update with Homebrew: \`brew install --cask its-ash/tap/noteit\` (or \`brew upgrade --cask noteit\`)." \
  --generate-notes \
  --latest

# --- Update the Homebrew tap ---
say "Updating $CASK in $TAP_REPO"
TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
gh repo clone "$TAP_REPO" "$TAP" -- -q --depth 1
perl -i -pe "s/^  version .*/  version \"$NEW\"/; s/^  sha256 .*/  sha256 \"$SHA\"/" "$TAP/$CASK"
grep -q "version \"$NEW\"" "$TAP/$CASK" && grep -q "sha256 \"$SHA\"" "$TAP/$CASK" \
  || die "could not update $CASK; the release is out, so update the tap by hand"
if command -v brew >/dev/null; then brew style "$TAP/$CASK" || say "brew style reported problems (not blocking)"; fi
git -C "$TAP" commit -q -am "noteit $NEW"
git -C "$TAP" push -q origin HEAD

say "Released NoteIt $NEW"
echo "  Release: https://github.com/$REPO/releases/tag/$TAG"
echo "  Users update with: brew upgrade --cask noteit"
