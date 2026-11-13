# VideoQuick

Read README.md and docs/SUPPORT.md before changes. Keep the app native, small and local.

- Never overwrite source media or existing outputs; publish verified copies atomically.
- One app instance and one persistent FIFO with at most one active export.
- Ordinary conversion preserves supported metadata, geometry, codec and audio; editor saves deliberately discard metadata/service tracks.
- Keep preview frames memory-only. No persistent thumbnail cache.
- Add meaningful regressions for behavior changes and run the relevant native/media checks.
- Never commit signing credentials, personal configuration, queue/history, user media, generated builds or logs.
- Public preview packages are ad-hoc signed and not notarized; describe that accurately.
