# Changelog

## Unreleased

- Add pkt-line parsing and smart HTTP protocol v2/v0 reference discovery
- Add smart HTTP fetch negotiation and bounded pack ingestion
- Add configured repository remotes and remote-tracking ref updates
- Add redacted Basic, Bearer, callback, and Git credential-helper authentication
- Add bounded SSH ref discovery and fetch through the system SSH client
- Add local, smart HTTP, and SSH push with refspecs, leases, atomic updates, and progress

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
