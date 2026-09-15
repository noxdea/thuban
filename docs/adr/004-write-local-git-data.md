# ADR 004: Write local Git data with native formats and locks

- Status: Accepted
- Date: 2026-09-15

## Context

Thuban already reads Git objects, indexes, and refs. Creating commits through a
separate library would duplicate those formats and expose internal models.
Repository mutation must remain compatible with Git and must not silently drop
index extensions or overwrite concurrent ref changes.

## Decision

Extend Thuban from a reader to a local Git implementation. Write loose objects
with Git's canonical header, retain optional index extensions as raw ordered
bytes, and remove only entry-dependent cache extensions after index mutation.
Use Git-compatible `.lock` files for index and ref replacement. Ref updates may
carry an expected old OID and fail with `Thuban::RefLockError` on mismatch.

Keep remote transfer, pack writing, and history operations other than commit and
amend outside this milestone.

## Consequences

Objects, indexes, refs, reflogs, and commits created by Thuban are readable by
Git. Interrupted writes leave lock files or unreachable objects instead of
partially written repository data. Higher-level merge, reset, stash, and remote
operations can build on these primitives later.
