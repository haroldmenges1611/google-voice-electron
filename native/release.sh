#!/bin/bash
# Builds and publishes the version in native/VERSION as a GitHub release (needs `gh` signed in).
# Attaches the Mac app (Timbre.zip) and, when the .NET SDK is installed, the Windows apps
# (Timbre-win-x64.exe, Timbre-win-arm64.exe). Installed copies pick it up through their updaters.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
./build.sh
ASSETS=(build/Timbre.zip)
if [ -x /opt/homebrew/bin/dotnet ] || command -v dotnet >/dev/null; then
  ../windows/build.sh
  ASSETS+=(../windows/build/Timbre-win-x64.exe ../windows/build/Timbre-win-arm64.exe)
fi
gh release create "v$VERSION" "${ASSETS[@]}" --title "Timbre $VERSION" --generate-notes
