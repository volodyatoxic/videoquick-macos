# Build from source

Requirements: Apple Silicon, macOS 14+, full Xcode, XcodeGen, Python 3, ripgrep, and an Apple Development signing certificate in your login keychain. The build script detects the certificate’s team locally; no team identifier or certificate is committed.

```sh
git clone https://github.com/volodyatoxic/videoquick-macos.git
cd videoquick-macos
scripts/build.sh
# Quit an existing VideoQuick before replacing it:
scripts/install.sh
```

The app is built at `build/DerivedData.noindex/Build/Products/Release/VideoQuick.app`. Xcode project files are generated from project.yml and are not tracked. The `.noindex` directory and build script keep build copies out of application launchers.

Set VIDEOQUICK_DEVELOPMENT_TEAM and VIDEOQUICK_SIGN_IDENTITY in your local environment only if you need to select a specific identity. Never commit signing credentials, profiles, or key material.

## Checks

```sh
scripts/test.sh
scripts/check-editor.sh
scripts/check-editor-commands.sh
scripts/check-icon-editor.sh
scripts/check-timeline-display.sh
scripts/check-history.sh
scripts/verify-release.sh /Applications/VideoQuick.app
```

Tests generate synthetic media with FFmpeg (`/opt/homebrew/bin/ffmpeg` by default); the application does not need FFmpeg at runtime. Set VIDEOQUICK_FFMPEG for another local test executable. Native checks need an active macOS GUI session and full Xcode. Generated media, logs and snapshots belong in ignored build/ directories.

## Package a preview DMG

```sh
scripts/package-dmg.sh
```

This copies the built app, applies ad-hoc signatures without personal development certificates, packages it with an Applications link and verifies the extracted bundle. It does not notarize the result. Production distribution needs your own Developer ID identity and Apple notarization workflow.

## Layout

- Sources/VideoQuickCore: inspection/export, metadata policies, queue, output publication and timeline geometry.
- Sources/VideoQuickApp: native windows, editor, history and progress strip.
- Sources/FinderExtension: MOV/MP4 context menu integration.
- Tests: core/media tests and native UI checks.
