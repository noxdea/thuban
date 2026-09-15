# ADR 005: Transfer Git data over bounded smart HTTP

- Status: Accepted
- Date: 2026-09-15

## Context

Remote transfer shares Git object IDs, pkt-line framing, pack decoding, and ref
semantics with Thuban's local implementation. Splitting it into another gem
would expose those internals and duplicate validation. Network input must be
bounded and must not weaken transport security while authentication is absent.

## Decision

Implement pkt-line and upload-pack negotiation inside Thuban, preferring smart
HTTP protocol v2 and accepting v0 fallback. Use Ruby's `Net::HTTP` and existing
pack/object writers without another runtime dependency. Spool bounded responses
to temporary files, verify the complete pack checksum before expansion, and cap
packet, HTTP, pack, object-count, deferred-delta, and expanded-object sizes.

Accept unauthenticated HTTP(S) URLs only. Reject credentials in URLs, explicit
credentials, redirects, SSH, shallow requests, and partial requests until their
dedicated milestones define secure behavior. Do not include response bodies or
URLs in authentication and HTTP errors.

Expand fetched packs into loose objects. This is simpler and immediately makes
them readable through `ObjectDatabase`; retaining pack/index files is deferred
until repository-scale benchmarks justify that optimization.

## Consequences

Git's `git-http-backend` can advertise refs and serve full or incremental packs
that Thuban verifies and reads without invoking Git at runtime. Large fetches
use bounded memory but may create many loose objects and temporarily use space
for both the HTTP response and extracted pack. Redirects and authenticated or
SSH remotes remain unsupported.
