# ADR 007: Delegate SSH transport to the system client

- Status: Accepted
- Date: 2026-09-15

## Context

SSH remotes need authentication, host verification, configuration, and process
lifecycle behavior that existing SSH clients already provide. Implementing that
stack in Ruby would duplicate security-sensitive code and add a dependency. Git
upload-pack already exposes the same pkt-line and pack stream consumed by the
smart HTTP implementation.

## Decision

Run the system `ssh` executable as a subprocess without a local shell and speak
protocol v0 with `git-upload-pack` over standard input and output. Reuse the
existing ref parser, fetch negotiation, bounded response spool, checksum checks,
and object ingestion. Accept `ssh://` and scp-like URLs after validating user,
host, port, and path fields; shell-quote the restricted remote path before it
reaches the remote login shell.

Accept an explicit `ssh:` argument array or shell-tokenized command string, then
fall back to a shell-tokenized `GIT_SSH_COMMAND` and finally `ssh`. Always add
batch mode and pass every local argument directly to process spawning. Bound the
whole exchange by the connection timeout, discard stderr, terminate the process
group on failure or close, and return errors that contain neither the URL nor
subprocess output.

## Consequences

SSH agents, host keys, and ordinary client configuration work without a Ruby SSH
dependency. Systems without an SSH executable can continue to use HTTP, while an
SSH attempt returns a transport error. SSH protocol v2 and interactive password
prompts are intentionally unsupported; the v0 transport provides the required
ref discovery and fetch behavior.
