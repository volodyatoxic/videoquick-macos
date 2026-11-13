#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
check_directory="${PWD}/build/ScrubChecks.noindex"
mkdir -p "$check_directory"
editor_source="${VIDEOQUICK_EDITOR_SOURCE:-${PWD}/Sources/VideoQuickApp/EditorDocument.swift}"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -emit-library -emit-module -module-name VideoQuickCore Sources/VideoQuickCore/*.swift -o "$check_directory/libVideoQuickCore.dylib" -emit-module-path "$check_directory/VideoQuickCore.swiftmodule" > "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -I "$check_directory" -L "$check_directory" -lVideoQuickCore -Xlinker -rpath -Xlinker "$check_directory" "$editor_source" Sources/VideoQuickApp/EditorWindowChrome.swift Sources/VideoQuickApp/EditorScrubWindow.swift Sources/VideoQuickApp/NativeCropPlayer.swift Tests/NativeScrubChecks.swift -o "$check_directory/ScrubChecks" >> "$check_directory/build.log" 2>&1 || { tail -25 "$check_directory/build.log"; exit 1; }
"${VIDEOQUICK_FFMPEG:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=s=640x360:d=12:r=60' -c:v libx264 -g 120 -bf 2 -pix_fmt yuv420p "$check_directory/fixture.mov"
"$check_directory/ScrubChecks" "${1:-$check_directory/fixture.mov}"
