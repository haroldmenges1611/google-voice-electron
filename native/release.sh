#!/bin/bash
# Builds and publishes the version in native/VERSION as a GitHub release (needs `gh` signed in).
# Installed copies of Timbre pick it up through the updater.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
./build.sh
gh release create "v$VERSION" build/Timbre.zip --title "Timbre $VERSION" --generate-notes
