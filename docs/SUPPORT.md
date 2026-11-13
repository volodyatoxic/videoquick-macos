# Formats and current limits

| | Ordinary conversion | Editor save |
| --- | --- | --- |
| Input | Local MOV / MP4; H.264 or HEVC, SDR, up to 8-bit | Same supported video family |
| Output container / codec | Source container and video codec | Source container and supported video codec |
| Dimensions / orientation | Preserved | Changed only by the chosen crop; no resolution menu |
| Audio | Copied without re-encoding | Retained unless muted; edit composition may re-encode |
| Metadata | Supported container/track metadata verified; supported camera timecode preserved | Source metadata, camera timecode, chapters and service tracks discarded |
| Original | Never overwritten | Never overwritten |

HDR, 10-bit, Dolby Vision, ProRes, multiple video tracks, unsupported track associations and alternative selection groups are rejected explicitly rather than silently changed. Editor saves with audible alternative-audio groups retain validation against accidental mixing. Unknown vendor metadata is not universally guaranteed.

Bitrate presets are average VBR targets. Audio and container overhead add bytes; choosing a rate above the source can make the result larger. Use a lower preset when the goal is a smaller file. There is no automatic bitrate or resolution selector in this release.

Finder scope covers the home directory and /Volumes. iCloud-only files, external-volume disconnects, all historical QuickTime variants, a full VoiceOver pass and complex A/V sync edits have not been exhaustively tested. Intel Macs are not supported.

All processing is local. The app has no upload, account or analytics service. Preview frames stay in memory. Queue/history are intentionally persistent; known export temporary files are cleaned after success/cancellation or recovered cleanup on launch. Closing the history window does not stop the worker.

The release is an early preview, not a guarantee for every camera format or media file. Please include macOS version, codec and the exact error when reporting a problem. Do not post private videos or personal file paths in public issues.
