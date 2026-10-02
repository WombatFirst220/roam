#!/bin/bash
# Publish a new version: tag, push, update the formula in the tap.
#   packaging/release.sh 1.0.1
# Expects the tap cloned next to this repo as ../homebrew-tap.
set -eu
V=${1:?usage: packaging/release.sh <version>}
cd "$(dirname "$0")/.."
TAP=../homebrew-tap
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
grep -q "^ROAM_VERSION=$V$" roam || { echo "ROAM_VERSION in roam is not $V"; exit 1; }
git tag -a "v$V" -m "roam $V"
git push origin main "v$V"
SHA=$(curl -fsSL "https://github.com/WombatFirst220/roam/archive/refs/tags/v$V.tar.gz" | shasum -a 256 | cut -d' ' -f1)
mkdir -p "$TAP/Formula"
sed -e "s/@VERSION@/$V/" -e "s/@SHA256@/$SHA/" -e '1,2d' packaging/roam.rb.in > "$TAP/Formula/roam.rb"
git -C "$TAP" add Formula/roam.rb
git -C "$TAP" commit -m "roam $V"
git -C "$TAP" push origin main
echo "released roam $V — on every Mac: brew upgrade roam"
