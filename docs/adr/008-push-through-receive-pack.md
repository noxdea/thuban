# ADR 008: Push through Git receive-pack

- Status: Accepted
- Date: 2026-09-15

## Context

Push must transfer all objects reachable from a new ref, reject stale updates,
and report whether each remote ref changed. The existing pack writer and smart
HTTP/SSH pkt-line transports already provide the required data path.

## Decision

Send Git protocol v0 receive-pack commands followed by the existing delta-free
PACK v2 stream. Require report-status, send the advertised old object ID with
every update, and validate the complete status response. Repository-level push
checks fast-forward updates before transfer and exposes explicit force,
force-with-lease, deletion, and atomic multi-ref operations.

Use the system `git-upload-pack` and `git-receive-pack` commands for local and
`file://` transports. Reuse the existing system SSH process lifecycle for SSH,
and the authenticated bounded request path for smart HTTP. Closing a connection
cancels its active HTTP request or subprocess.

## Consequences

Local, HTTP, and SSH pushes share one pack and status implementation. The remote
server remains the final authority for hooks and concurrent updates. Packfiles
contain whole objects without delta generation; large-repository optimization
can be added independently without changing the push API.
