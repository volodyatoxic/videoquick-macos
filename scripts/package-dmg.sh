#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="${1:-${PWD}/build/DerivedData.noindex/Build/Products/Release/VideoQuick.app}"
version='0.1.0'
release_dir="${PWD}/build/releases"
scratch_root="${PWD}/build/DMG.noindex"
mkdir -p "$release_dir" "$scratch_root"
[[ -d "$source_app" ]] || { print -u2 'Build VideoQuick first, or pass the path to a tested app bundle.'; exit 1; }
scripts/verify-release.sh "$source_app"
workspace="$(mktemp -d "$scratch_root/package.XXXXXX")"
stage="$workspace/stage"
mountpoint="$workspace/mount"
mkdir -p "$stage" "$mountpoint"
cleanup() {
  hdiutil detach "$mountpoint" >/dev/null 2>&1 || true
  /bin/rm -rf "$workspace"
}
trap cleanup EXIT
# All signing mutations apply only to this temporary copy.
ditto "$source_app" "$stage/VideoQuick.app"
python3 - "$stage/VideoQuick.app" "$version" <<'VERSION'
from pathlib import Path
import sys, plistlib
app=Path(sys.argv[1])
for relative in ['Contents/Info.plist','Contents/PlugIns/VideoQuickFinder.appex/Contents/Info.plist']:
    p=app/relative
    with p.open('rb') as f: info=plistlib.load(f)
    info['CFBundleShortVersionString']=sys.argv[2]
    with p.open('wb') as f: plistlib.dump(info,f,sort_keys=False)
for profile in app.rglob('embedded.provisionprofile'): profile.unlink()
VERSION
# Remove local debug/object symbols before signing. A text-only strings scan
# misses Mach-O string-table paths, so check raw bytes in the copied executables.
/usr/bin/strip -S -x "$stage/VideoQuick.app/Contents/MacOS/VideoQuick" >/dev/null 2>&1
/usr/bin/strip -S -x "$stage/VideoQuick.app/Contents/PlugIns/VideoQuickFinder.appex/Contents/MacOS/VideoQuickFinder" >/dev/null 2>&1
python3 - "$stage/VideoQuick.app" <<'PRIVACY'
from pathlib import Path
import sys
app=Path(sys.argv[1])
for executable in [app/'Contents/MacOS/VideoQuick',app/'Contents/PlugIns/VideoQuickFinder.appex/Contents/MacOS/VideoQuickFinder']:
    data=executable.read_bytes()
    if b'/Users/' in data or b'/var/folders/' in data:
        raise SystemExit('Private build paths remain in ' + executable.name)
PRIVACY
codesign --force --sign - --options runtime --entitlements Resources/Finder.entitlements "$stage/VideoQuick.app/Contents/PlugIns/VideoQuickFinder.appex" >/dev/null 2>&1
codesign --force --sign - --options runtime "$stage/VideoQuick.app" >/dev/null 2>&1
scripts/verify-release.sh "$stage/VideoQuick.app"
codesign --display --verbose=2 "$stage/VideoQuick.app" 2>&1 | python3 -c 'import sys; s=sys.stdin.read(); assert "Signature=adhoc" in s and "Authority=" not in s, "Unexpected signing identity in preview"'
cp LICENSE "$stage/LICENSE.txt"
cat > "$stage/INSTALL.txt" <<'INSTALL'
VideoQuick — Apple Silicon / macOS 14+

1. Drag VideoQuick.app to Applications.
2. Eject this disk image and open the installed copy.
3. VideoQuick > Настроить меню Finder… opens Finder extension settings.
   Enable VideoQuick Finder if required.
4. Right-click MOV or MP4 in Finder to convert or edit.

This is a non-notarized developer preview with ad-hoc signatures.
macOS may block opening it. Do not disable security protections.
Source and installation details:
https://github.com/volodyatoxic/videoquick-macos

VideoQuick code: MIT. Feather icons: MIT, Cole Bemis (license in app bundle).
INSTALL
ln -s /Applications "$stage/Applications"
dmg="$release_dir/VideoQuick-$version-arm64.dmg"
hdiutil create -quiet -volname VideoQuick -srcfolder "$stage" -format UDZO -fs HFS+ "$workspace/VideoQuick.dmg"
hdiutil verify "$workspace/VideoQuick.dmg" > "$workspace/verify.log"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$workspace/VideoQuick.dmg"
scripts/verify-release.sh "$mountpoint/VideoQuick.app"
[[ -L "$mountpoint/Applications" ]] || { print -u2 'Missing Applications link'; exit 1; }
[[ "$(readlink "$mountpoint/Applications")" == /Applications ]] || exit 1
hdiutil detach -quiet "$mountpoint"
mv "$workspace/VideoQuick.dmg" "$dmg"
(cd "$release_dir" && shasum -a 256 "${dmg:t}" > SHA256SUMS.txt)
print "Packaged non-notarized preview: $dmg"
