#!/bin/bash
# Builds BOTH apps and publishes the version in ./VERSION as a GitHub release (needs `gh` signed in).
# Assets: Timbre.zip (Mac), Timbre-win-x64.exe, Timbre-win-arm64.exe (Windows). Installed copies of
# either app pick it up through their built-in updaters.
set -euo pipefail
cd "$(dirname "$0")"
./check.sh
./build.sh all
VERSION="$(cat VERSION)"
gh release create "v$VERSION" native/build/Timbre.zip windows/build/Timbre-win-x64.exe windows/build/Timbre-win-arm64.exe \
  --title "Timbre $VERSION" --generate-notes
