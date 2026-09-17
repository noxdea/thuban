# Changelog

## Unreleased

## 0.5.0 - 2026-09-17

- Expose parsed commit signatures and separate author and committer identities in `commit!`
- Add current author and committer identity lookup with `Repository#signature`
- Add bounded commit history traversal with `Repository#each_commit`
- Add cancellable high-level fetch and push controls and fast-forward-only pull
- Honor `core.filemode` when reporting worktree changes

## 0.4.1 - 2026-09-17

- Load remote transport providers only when remote operations are used

## 0.4.0 - 2026-09-15

- Add pkt-line parsing and smart HTTP protocol v2/v0 reference discovery
- Add smart HTTP fetch negotiation and bounded pack ingestion
- Add configured repository remotes and remote-tracking ref updates
- Add redacted Basic, Bearer, callback, and Git credential-helper authentication
- Add bounded SSH ref discovery and fetch through the system SSH client
- Add local, smart HTTP, and SSH push with refspecs, leases, atomic updates, and progress
- Add fetch progress, shallow depth negotiation, and `blob:none` partial fetches

## 0.3.0 - 2026-09-15

- Add loose object, tree, and commit writing
- Add index mutation with v2/v3/v4 encoding and raw optional-extension preservation
- Add locked loose and packed ref updates with reflogs and optimistic old-OID checks
- Add index-to-tree commit creation and amend support
- Add merge-base, reset, and three-way cherry-pick and revert operations
- Add Git-compatible stash push, list, and three-way pop operations
- Add delta-free PACK v2 writing with progress and checksum reporting

## 0.2.0 - 2026-09-14

- Add `Thuban::IgnoreMatcher.load` with Git-compatible ignore source precedence
- Publish the ignore matcher API and type signatures

## 0.1.0 - 2026-09-12

- Initial release
