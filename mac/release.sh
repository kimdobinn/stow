#!/bin/zsh
# Builds Stow.app (Release, signed with the Apple Development identity in project.yml), zips it and
# publishes it as a GitHub pre-release tagged mac-v<version>. Installed copies of Stow check these
# releases once a day and update themselves (Account › Updates).
#
#   mac/release.sh                  # notes: the commit subjects since the last Mac release
#   mac/release.sh "What changed"   # your own notes
#
# Bump CFBundleShortVersionString (and CFBundleVersion) in project.yml and push that commit first.
# Pre-releases keep Obtainium on the Android releases (it reads /releases/latest, which skips them).
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
cd "$script_dir"

team=LYD6WV79Y4
version=$(sed -nE 's/^ *CFBundleShortVersionString: "(.*)"/\1/p' project.yml)
[[ -n $version ]] || { echo "Couldn't read CFBundleShortVersionString from project.yml." >&2; exit 1; }
tag="mac-v$version"

if [[ -n $(git status --porcelain) ]]; then
  echo "Commit your changes first." >&2; exit 1
fi
git fetch --quiet origin
if [[ $(git rev-parse HEAD) != $(git rev-parse '@{upstream}') ]]; then
  echo "Push (or pull) first: this commit isn't the one on GitHub." >&2; exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag is already released. Bump CFBundleShortVersionString in project.yml." >&2; exit 1
fi

/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild -quiet -project Stow.xcodeproj -scheme Stow -configuration Release \
  -derivedDataPath .build-release clean build
app=.build-release/Build/Products/Release/Stow.app

# What the app will check before installing it: same version, a valid signature from the team.
built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $built == "$version" ]] || { echo "Built version $built, expected $version." >&2; exit 1; }
codesign --verify --deep --strict "$app"
codesign -dv "$app" 2>&1 | grep -x "TeamIdentifier=$team" >/dev/null || { echo "Stow.app isn't signed by team $team." >&2; exit 1; }

zip="$repo_root/Stow-Mac-$version.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d ' ' -f 1)
print -r -- "$sha  ${zip:t}" > "$zip.sha256"

if (( $# > 0 )); then
  notes=$1
else
  previous=$(git describe --tags --abbrev=0 --match 'mac-v*' 2>/dev/null || true)
  notes=$(git log --format='- %s' ${previous:+$previous..}HEAD -- . | head -20)
fi
notes+=$'\n\n'"SHA-256: $sha"

gh release create "$tag" "$zip" "$zip.sha256" --prerelease --target "$(git rev-parse HEAD)" \
  --title "Stow for Mac $version" --notes "$notes"
git fetch --quiet --tags origin
echo "Released $tag with ${zip:t} (SHA-256 $sha)."
