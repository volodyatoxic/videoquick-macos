#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
bundle="${1:-${PWD}/build/DerivedData.noindex/Build/Products/Release/VideoQuick.app}"
codesign --verify --deep --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist" "$bundle/Contents/PlugIns/VideoQuickFinder.appex/Contents/Info.plist"
[[ "$(lipo -archs "$bundle/Contents/MacOS/VideoQuick")" == "arm64" ]]
[[ "$(lipo -archs "$bundle/Contents/PlugIns/VideoQuickFinder.appex/Contents/MacOS/VideoQuickFinder")" == "arm64" ]]
git diff --check
print 'Verified: arm64 app + embedded Finder extension, signature and plists.'
