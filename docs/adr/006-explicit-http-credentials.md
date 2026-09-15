# ADR 006: Resolve HTTP credentials through explicit providers

- Status: Accepted
- Date: 2026-09-15

## Context

Smart HTTP remotes commonly require Basic or Bearer authentication. Applications
may hold fixed credentials, refresh tokens at runtime, or delegate storage to
Git's configured credential helpers. Credentials must not be accepted in remote
URLs or exposed through errors, inspection output, subprocess arguments, or
redirects.

## Decision

`Remote.open(credentials:)` accepts only credential providers created by
`Remote::Credentials`. Provide fixed Basic and Bearer values, a lazy callback,
and Git credential-helper lookup. Resolve each provider once per connection and
send its authorization value preemptively on every request for that connection.

Invoke `git credential fill` without a shell from Thuban, communicate through the
standard input/output protocol, disable interactive prompting and Git tracing,
bound its output and runtime, and discard stderr. When a helper name is supplied,
clear configured helpers before selecting it. Do not include provider failures or
server response bodies in `AuthenticationError` causes or messages.

Continue to reject URL-embedded credentials and all HTTP redirects. This avoids
ambiguous precedence and prevents forwarding an authorization header to another
origin.

## Consequences

Callers can authenticate fetches without Thuban storing credentials globally or
adding a runtime dependency. A callback can refresh a token before opening a new
connection; credentials are intentionally stable for the lifetime of one
connection. Redirecting remotes must be configured with their final URL.
