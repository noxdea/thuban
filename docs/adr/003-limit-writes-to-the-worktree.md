# ADR 003: Limit writes to guarded worktree operations

- Status: Accepted
- Date: 2026-09-12

## Context

Repository writes can corrupt history or overwrite unrelated files when path
and replacement behavior are ambiguous.

## Decision

Expose atomic worktree replacement with path and symlink checks, plus guarded
checkout. Do not expose history-rewriting operations.

## Consequences

Callers retain control of content transformations while Thuban owns filesystem
safety. Broader repository mutation remains outside the gem.
