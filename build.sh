#!/bin/bash
# Build apple-calendar-mcp (EventKit: Calendar + Reminders). Run on the Mac.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O main.swift -o apple-calendar-mcp.new -licucore \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
mv -f apple-calendar-mcp.new apple-calendar-mcp
# Stable designated requirement (identifier, not cdhash) so TCC grants survive rebuilds.
# ponytail: any local ad-hoc binary signed with this identifier passes it; use a real cert if that matters.
codesign --force --sign - --identifier local.apple-calendar-mcp \
  -r='designated => identifier "local.apple-calendar-mcp"' apple-calendar-mcp
echo "built $(pwd)/apple-calendar-mcp"
