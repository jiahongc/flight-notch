# Contributing to Flight Notch

Build with Xcode 26 or later on macOS. Open `FlightNotch.xcodeproj`, select the `FlightNotch` scheme, and run `swift test` plus `./build.sh` before submitting a change.

Keep pull requests focused on one behavior. Describe the problem, resulting behavior, and validation. Target `main`. Application source belongs in `FlightNotch/`.

## Working principles

- Prefer native APIs and small, explicit code over new dependencies.
- Keep the app usable without API keys or paid subscriptions.
- Respect community API limits. Do not bypass cooldowns, scrape protected endpoints, or invent missing flight details.
- Label route and phase estimates honestly. Preserve missing-data and stale-data states.
- Preserve macOS permission checks, notch camera clearance, Reduce Motion, and keyboard/accessibility labels.
- Add a focused regression test for changes to parsing, filtering, route behavior, or interaction state.

For UI changes, check map and satellite views, aircraft selection, narrow layouts, auto-hide, Always open, and Settings stacking. Location permission, physical notch geometry, and display changes also need native manual checks when affected.

## Screenshots and recordings

Disable automatic location and use the public city-center fallback. Capture only the Flight Notch window. Do not include a desktop, notifications, precise user coordinates, account information, or audio. Review media before adding it to `docs/media/`. Use small PNGs, an H.264 MP4, and an optimized GIF preview.

Keep build products, local working plans, logs, personal settings, credentials, and raw recording frames out of Git. Include only reviewed media and reproducible source changes.

## Reporting a bug

Include the macOS/Xcode version, steps to reproduce, expected behavior, and whether the issue occurs with location enabled or the fallback. For a route problem, a public callsign and approximate observation time help; do not include your own coordinates.

By contributing, you agree to distribute your changes under this repository's GPL-3.0 license. Preserve upstream notices and attribution.
