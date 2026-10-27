#!/bin/bash
# Builds self-contained single-file Windows apps (x64 and ARM64) from macOS or Windows.
# Needs the .NET SDK (macOS: brew install dotnet). Output: windows/build/Timbre-win-x64.exe, Timbre-win-arm64.exe
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
export DOTNET_ROOT="${DOTNET_ROOT:-/opt/homebrew/opt/dotnet/libexec}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

VERSION="${VERSION:-$(cat ../VERSION)}"
rm -rf build
mkdir -p build
for rid in win-x64 win-arm64; do
  dotnet publish Timbre.csproj -c Release -r "$rid" --self-contained true \
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none -p:Version="$VERSION" \
    -o "build/$rid"
  cp "build/$rid/Timbre.exe" "build/Timbre-$rid.exe"
done
ls -la build/*.exe
