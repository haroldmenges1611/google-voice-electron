#!/bin/bash
# Quick check that BOTH apps still compile. Run after every code change (a few seconds).
# Nothing is run or packaged; use ./build.sh for real builds.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
export DOTNET_ROOT="${DOTNET_ROOT:-/opt/homebrew/opt/dotnet/libexec}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
status=0

echo "== Mac (Swift) =="
if swiftc -O -swift-version 5 -typecheck native/Sources/*.swift; then echo "ok"; else echo "FAILED"; status=1; fi

echo "== Windows (C#) =="
if dotnet build windows/Timbre.csproj -c Release -r win-x64 --self-contained false -nologo -v q 2>&1 | grep -E "error|warning CS" ; then
  echo "FAILED"; status=1
else
  echo "ok"
fi

[ $status -eq 0 ] && echo "Both compile." || echo "A build is broken."
exit $status
