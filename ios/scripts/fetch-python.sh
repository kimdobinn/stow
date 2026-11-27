#!/bin/bash
# Downloads the embedded Python (BeeWare's Python-Apple-support, CPython's official iOS build) and
# the pure-Python packages the app runs, into ios/Vendor/ (git-ignored). Every download is pinned
# and checked against its sha256, so a build never runs code nobody looked at.
#
#   ios/scripts/fetch-python.sh          # skips what is already there
#   ios/scripts/fetch-python.sh --force  # downloads everything again
#
# To update yt-dlp: change YTDLP_VERSION and YTDLP_SHA256 (from https://pypi.org/project/yt-dlp/#files,
# the py3-none-any wheel), and YTDLP_EJS_* to the version yt-dlp's "pin" extra names.
set -euo pipefail

PYTHON_TAG="3.14-b14"
PYTHON_ARCHIVE="Python-3.14-iOS-support.b14.tar.gz"
PYTHON_SHA256="703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee"

# name|version|wheel url|sha256
WHEELS=(
  "yt-dlp|2026.11.23|https://files.pythonhosted.org/packages/py3/y/yt-dlp/yt_dlp-2026.11.23-py3-none-any.whl|e9188e0c559905f7ee05acc1ba0b6fb3f310e7565bf6dea5f62b5300e0775e35"
  # yt-dlp's challenge solver scripts (JavaScript), run with JavaScriptCore; the version yt-dlp pins.
  "yt-dlp-ejs|0.8.0|https://files.pythonhosted.org/packages/py3/y/yt-dlp-ejs/yt_dlp_ejs-0.8.0-py3-none-any.whl|79300e5fca7f937a1eeede11f0456862c1b41107ce1d726871e0207424f4bdb4"
  # iOS has no CA bundle that OpenSSL can read: Python's ssl is pointed at certifi's cacert.pem.
  "certifi|2026.11.20|https://files.pythonhosted.org/packages/py3/c/certifi/certifi-2026.11.20-py3-none-any.whl|7422df25243767b9877031a2248cb14d09ddac9beee846f4cef3d5c9191d488f"
)

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$IOS_DIR/Vendor"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

sha256_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

fetch() { # url, destination file, expected sha256
  local url=$1 dest=$2 expected=$3
  echo "Downloading $url"
  curl --fail --location --silent --show-error --retry 3 -o "$dest" "$url"
  local actual
  actual=$(sha256_of "$dest")
  if [ "$actual" != "$expected" ]; then
    echo "error: sha256 mismatch for $url" >&2
    echo "  expected $expected" >&2
    echo "  got      $actual" >&2
    rm -f "$dest"
    exit 1
  fi
}

mkdir -p "$VENDOR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stow-fetch-python.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Python.xcframework
PY_STAMP="$VENDOR/Python.xcframework/.stow-version"
if [ $FORCE = 1 ] || [ ! -f "$PY_STAMP" ] || [ "$(cat "$PY_STAMP")" != "$PYTHON_SHA256" ]; then
  fetch "https://github.com/beeware/Python-Apple-support/releases/download/$PYTHON_TAG/$PYTHON_ARCHIVE" \
    "$WORK/python.tar.gz" "$PYTHON_SHA256"
  mkdir -p "$WORK/python"
  tar -xzf "$WORK/python.tar.gz" -C "$WORK/python"
  rm -rf "$VENDOR/Python.xcframework"
  mv "$WORK/python/Python.xcframework" "$VENDOR/Python.xcframework"
  cp "$WORK/python/VERSIONS" "$VENDOR/Python-VERSIONS.txt"
  echo "$PYTHON_SHA256" > "$PY_STAMP"
else
  echo "Python.xcframework $PYTHON_TAG is already there"
fi

# site-packages: pure-Python wheels, unpacked as they are (a wheel is a zip of the install tree).
SITE="$VENDOR/site-packages"
SITE_STAMP="$SITE/.stow-versions"
WANT_STAMP=$(printf '%s\n' "${WHEELS[@]}")
if [ $FORCE = 1 ] || [ ! -f "$SITE_STAMP" ] || [ "$(cat "$SITE_STAMP")" != "$WANT_STAMP" ]; then
  rm -rf "$WORK/site"
  mkdir -p "$WORK/site"
  for entry in "${WHEELS[@]}"; do
    IFS='|' read -r name version url sha <<< "$entry"
    fetch "$url" "$WORK/$name.whl" "$sha"
    unzip -q -o "$WORK/$name.whl" -d "$WORK/site"
  done
  # Bytecode is compiled on the phone into Caches (the app bundle is read-only and signed).
  find "$WORK/site" -name '__pycache__' -type d -prune -exec rm -rf {} +
  # Man pages and shell completions.
  rm -rf "$WORK/site"/*.data
  rm -rf "$SITE"
  mv "$WORK/site" "$SITE"
  echo "$WANT_STAMP" > "$SITE_STAMP"
else
  echo "site-packages are up to date"
fi

echo "Vendor is ready:"
grep -E "Python version|Build" "$VENDOR/Python-VERSIONS.txt" | sed 's/^/  /'
for entry in "${WHEELS[@]}"; do
  IFS='|' read -r name version _ _ <<< "$entry"
  echo "  $name $version"
done
