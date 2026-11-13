#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
check_directory="${PWD}/build/HistoryChecks.noindex"
mkdir -p "$check_directory"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library Sources/VideoQuickApp/HistoryMediaStore.swift Tests/NativeHistoryChecks.swift -o "$check_directory/HistoryChecks"
"${VIDEOQUICK_FFMPEG:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -y -f lavfi -i 'color=c=red:s=320x180:d=2:r=25' -f lavfi -i 'color=c=green:s=320x180:d=2:r=25' -f lavfi -i 'color=c=blue:s=320x180:d=2:r=25' -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]' -map '[v]' -c:v libx264 -pix_fmt yuv420p "$check_directory/fixture.mov"
"$check_directory/HistoryChecks" "$check_directory/fixture.mov"
