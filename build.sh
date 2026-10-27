#!/bin/bash
# Builds the apps. Usage: ./build.sh [all|mac|windows]   (default: all)
#   Mac:     native/build/Timbre.app and Timbre.zip              (needs Xcode command line tools)
#   Windows: windows/build/Timbre-win-x64.exe, -arm64.exe        (needs the .NET SDK; macOS: brew install dotnet)
# Both are built from the version in ./VERSION.
set -euo pipefail
cd "$(dirname "$0")"
target="${1:-all}"
case "$target" in all|mac|windows) ;; *) echo "usage: $0 [all|mac|windows]" >&2; exit 2 ;; esac

if [ "$target" != "windows" ]; then native/build.sh; fi
if [ "$target" != "mac" ]; then windows/build.sh; fi
echo "Built $target at version $(cat VERSION)"
