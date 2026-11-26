#!/bin/zsh
# Builds the signed release APK and publishes it as a GitHub release, so phones can install and
# update it with Obtainium (see the README).
#
#   android/release.sh                  # notes: the commit subjects since the last release
#   android/release.sh "What changed"   # your own notes
#
# Bump versionCode and versionName in app/build.gradle.kts and push that commit first. The release
# is tagged v<versionName> on the pushed commit.
set -euo pipefail

cd "${0:A:h}"
repo_root=${0:A:h:h}

[[ -f keystore/keystore.properties ]] || { echo "No signing key in android/keystore/." >&2; exit 1; }

version=$(sed -nE 's/^ *versionName = "(.*)"/\1/p' app/build.gradle.kts)
[[ -n $version ]] || { echo "Couldn't read versionName from app/build.gradle.kts." >&2; exit 1; }
tag="v$version"

if [[ -n $(git status --porcelain) ]]; then
  echo "Commit your changes first." >&2; exit 1
fi
git fetch --quiet origin
if [[ $(git rev-parse HEAD) != $(git rev-parse '@{upstream}') ]]; then
  echo "Push (or pull) first: this commit isn't the one on GitHub." >&2; exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag is already released. Bump versionName (and versionCode) in app/build.gradle.kts." >&2; exit 1
fi

./gradlew -q :app:assembleRelease
apk="$repo_root/Stow-$version.apk"
cp app/build/outputs/apk/release/app-release.apk "$apk"

if (( $# > 0 )); then
  notes=$1
else
  previous=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  notes=$(git log --format='- %s' ${previous:+$previous..}HEAD -- . | head -20)
fi

gh release create "$tag" "$apk" --target "$(git rev-parse HEAD)" --title "Stow $version" --notes "$notes"
git fetch --quiet --tags origin
echo "Released $tag with $(basename "$apk")."
