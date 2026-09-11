# ADR 001: Delegate text differences to Porrima

- Status: Accepted
- Date: 2026-09-12

## Context

Repository history needs line correspondence for blame, but a Git reader does
not need to own a general text-difference implementation.

## Decision

Depend on Porrima for blame line matching and accept an injectable `differ:`
object that responds to `edits(before, after)`.

## Consequences

Thuban contains no diff algorithm. Callers compose repository content with
Porrima directly, and blame can be tested with a small substitute.
