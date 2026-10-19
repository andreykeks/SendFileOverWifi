# Shared UI localization

`ui.json` is the canonical UI catalogue for all SendFile over WiFi applications.
It contains the six supported languages: `en`, `ru`, `it`, `es`, `pt`, and `cn`.

Every platform bundles this file into its own distributable application and reads
it at runtime. A platform may retain a built-in fallback only to remain usable
when a developer launches an incomplete local build; new UI strings must be
added to `ui.json`, not to a platform-local catalogue.

Protocol tokens, HTTP status reasons, header names and debug-only identifiers
are not UI strings and remain ASCII protocol values.
