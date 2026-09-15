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

Build local history operations and stash from the same object, index, and ref
writers. Apply cherry-pick and revert as path-level three-way changes only when
the tracked state is clean, and reject merge commits until mainline selection is
part of the public API. Store stashes in Git's standard commit and reflog layout.
Write PACK v2 streams without delta generation; this keeps the first writer
interoperable while reserving compression heuristics for later measurement.

Keep remote transfer, merge, and streaming pack ingestion outside this
milestone.

## Consequences

Objects, indexes, refs, reflogs, commits, stashes, and packs created by Thuban are
readable by Git. Worktree-changing history operations acquire index and ref
locks, preflight object reads and collisions, and restore worktree files if index
replacement fails. Interrupted object creation may leave unreachable objects,
which Git can safely prune. Remote operations can build on these primitives
later.
