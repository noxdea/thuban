# 009: Keep shallow and partial fetch state Git-compatible

- Status: Accepted
- Date: 2026-09-15

## Context

Fetch needs bounded progress plus the protocol v0/v2 `shallow` and `filter`
features without creating a second repository-state format. Servers may omit
blobs intentionally, while malformed negotiation must still fail explicitly.

## Decision

Thuban accepts positive 32-bit `depth` values and only `filter=blob:none`. It
sends either option only when upload-pack advertises the corresponding feature.
Both HTTP and delegated SSH reuse the existing pkt-line, sideband, tempfile, and
pack-reader limits.

The server's `shallow` and `unshallow` response is validated after pack ingestion
and written atomically to the common Git directory. A configured partial remote
is marked with Git's `remote.<name>.promisor` and
`remote.<name>.partialclonefilter` settings. Thuban does not invent loose-object
promise markers: an omitted blob remains absent and `ObjectDatabase#read` raises
`KeyError`, not `CorruptObject`.

## Consequences

Git and Thuban agree on shallow boundaries, and Git can lazily retrieve an
omitted object from a configured promisor remote. Thuban itself does not perform
implicit network access while reading objects; callers explicitly fetch missing
objects when needed.
