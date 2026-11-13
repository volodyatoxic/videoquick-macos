#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
check_directory="${PWD}/build/LongVideoChecks.noindex"
mkdir -p "$check_directory"
media_directory="$(mktemp -d "${TMPDIR%/}/videoquick-long-check.XXXXXX")"
trap 'rm -rf "$media_directory"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -emit-library -emit-module -module-name VideoQuickCore Sources/VideoQuickCore/*.swift -o "$check_directory/libVideoQuickCore.dylib" -emit-module-path "$check_directory/VideoQuickCore.swiftmodule" > "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -I "$check_directory" -L "$check_directory" -lVideoQuickCore -Xlinker -rpath -Xlinker "$check_directory" Sources/VideoQuickApp/EditorDocument.swift Tests/NativeLongVideoChecks.swift -o "$check_directory/LongVideoChecks" >> "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
ffmpeg_bin="${VIDEOQUICK_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
"$ffmpeg_bin" -hide_banner -loglevel error -y -f lavfi -i 'color=c=blue:s=320x180:d=2:r=30' -c:v libx264 -preset ultrafast -g 30 -pix_fmt yuv420p "$media_directory/seed.mov"
"$ffmpeg_bin" -hide_banner -loglevel error -y -stream_loop 5399 -i "$media_directory/seed.mov" -t 10800 -c copy -movflags +faststart "$media_directory/three-hours.mov"
"$check_directory/LongVideoChecks" "$media_directory/seed.mov"
"$check_directory/LongVideoChecks" "$media_directory/three-hours.mov"
