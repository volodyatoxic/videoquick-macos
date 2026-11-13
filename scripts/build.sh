#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodegen generate --spec project.yml
mkdir -p build
team="${VIDEOQUICK_DEVELOPMENT_TEAM:-$(python3 scripts/signing-team.py)}"
if ! xcodebuild -project VideoQuick.xcodeproj -scheme VideoQuick -configuration Release -derivedDataPath build/DerivedData.noindex CODE_SIGN_IDENTITY="${VIDEOQUICK_SIGN_IDENTITY:-Apple Development}" DEVELOPMENT_TEAM="$team" build > build/build.log 2>&1; then
  rg 'error:|warning:|BUILD FAILED' build/build.log | tail -35
  exit 1
fi
# Xcode registers generated app bundles even inside an unindexed directory.
# Keep application launchers pointed at the installed copy only.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${PWD}/build/DerivedData.noindex/Build/Products/Release/VideoQuick.app" >/dev/null 2>&1 || true
print "Built: ${PWD}/build/DerivedData.noindex/Build/Products/Release/VideoQuick.app"
