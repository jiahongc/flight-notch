# Security policy

Report security problems privately using GitHub's **Report a vulnerability** action when it is available. If it is unavailable, open an issue requesting a private reporting channel without including exploit details or personal information. Do not post tokens, exact user coordinates, private logs, or desktop recordings in an issue.

The current development version on `main` is maintained. This is a locally signed source build, not a notarized binary release.

Flight Notch requests macOS location permission and sends detection coordinates to the selected aircraft feed. It does not require paid API credentials, store location/flight history, or include analytics. Community API responses are treated as untrusted data; invalid coordinates, stale aircraft, and implausible routes are rejected.

Security changes must retain permission checks, rate-limit handling, and missing-data behavior. The build verifies that the signed app has its location entitlement.
