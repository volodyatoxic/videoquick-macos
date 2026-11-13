#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source="${PWD}/build/DerivedData.noindex/Build/Products/Release/VideoQuick.app"
target='/Applications/VideoQuick.app'
if pgrep -x VideoQuick >/dev/null; then
  print -u2 'Quit VideoQuick before installing an update. Existing queued jobs are kept.'
  exit 1
fi
scripts/verify-release.sh "$source"
if [[ -d "$target" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")" != 'com.volodyatoxic.VideoQuick' ]]; then
  print -u2 'A different app already occupies the installation path.'
  exit 1
fi
# Stop the previous extension before replacement. Killing it after enabling can
# terminate the new instance Finder has just launched and leave its menu absent.
if [[ -d "$target/Contents/PlugIns/VideoQuickFinder.appex" ]]; then
  pluginkit -e ignore -i com.volodyatoxic.VideoQuick.Finder
  trap 'pluginkit -e use -i com.volodyatoxic.VideoQuick.Finder >/dev/null 2>&1 || true' EXIT
  pkill -x VideoQuickFinder || true
fi
ditto "$source" "$target"
codesign --verify --deep --strict "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$source" >/dev/null 2>&1 || true
pluginkit -a "$target/Contents/PlugIns/VideoQuickFinder.appex"
pluginkit -e use -i com.volodyatoxic.VideoQuick.Finder
trap - EXIT
print "Installed: $target"
