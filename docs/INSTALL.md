# Install VideoQuick

Requires an Apple Silicon Mac and macOS 14 or later. Intel Macs are not supported.

1. Download the DMG from [Releases](https://github.com/volodyatoxic/videoquick-macos/releases/tag/v0.1.0).
2. Open the disk image, then drag VideoQuick to Applications.
3. Eject the image and launch the copy in Applications.
4. Use **VideoQuick → Настроить меню Finder…** to open Finder extension settings. Enable **VideoQuick Finder** if necessary. Settings labels and locations vary by macOS version; search System Settings for “Extensions” or “Finder”.
5. Right-click a local MOV or MP4 in Finder. **Конвертировать** opens the bitrate submenu; **Изменить…** opens the editor.

## Preview signing status

Version 0.1.0 is a developer preview. The app and embedded Finder extension are ad-hoc signed, not Developer ID signed or notarized. macOS may block a downloaded copy, and installation on other Macs has not been independently verified. Do not disable system security protections. You can instead [build locally](BUILDING.md), or wait for a notarized release.

Apple explains the distribution requirements in [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Updates

Quit VideoQuick, replace the app in Applications with the new version, then reopen it. Do not overwrite a running app. Existing queue/history live separately from the application bundle. Unfinished jobs recovered after an unexpected exit require explicit continuation.

## If Finder commands are missing

Open the installed copy once, check that the Finder extension is enabled, and reopen the Finder window. Avoid keeping multiple installed copies. The source-build installer also registers the embedded extension; see [BUILDING.md](BUILDING.md).

## Verify the download

The release includes SHA256SUMS.txt. In the download folder run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

A matching checksum verifies download integrity; it does not replace Apple notarization.
