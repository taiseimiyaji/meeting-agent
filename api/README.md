# Local API contract

`openapi.yaml` is the shared contract between the native agent and the local web UI.

Security requirements:

- Bind to `127.0.0.1` by default.
- Require an unpredictable per-launch session token for every HTTP endpoint except health.
- Require a separate CSRF token for mutations.
- Validate both `Host` and `Origin`; localhost is not an authentication boundary.
- Authenticate WebSocket upgrades with the subprotocols `meeting-agent` and
  `token.<base64url-session-token>`. Validate the second value, but select and
  echo only `meeting-agent`; never put the session token in the URL.

The native implementation is authoritative. Client types may be generated from this document, but generated code must not silently widen enums or make required evidence fields optional.
