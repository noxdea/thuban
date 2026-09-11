# ADR 002: Keep repository access in pure Ruby

- Status: Accepted
- Date: 2026-09-12

## Context

Shelling out to Git or requiring a native extension would add platform,
installation, and process-management constraints.

## Decision

Read supported Git files and formats in Ruby with the standard library. Do not
invoke an external `git` process from the library.

## Consequences

The runtime remains portable and embeddable. Thuban explicitly supports a
bounded subset of SHA-1 repository formats rather than every Git extension.
