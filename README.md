<h1 align="center">Thuban</h1>

<p align="center">
  <strong>A pure Ruby Git implementation for local repositories and remote transfers</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/thuban"><img src="https://img.shields.io/gem/v/thuban.svg?colorB=319e8c" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/thuban"><img src="https://img.shields.io/gem/dt/thuban.svg" alt="Downloads"></a>
  <a href="https://github.com/noxdea/thuban/actions/workflows/main.yml"><img src="https://github.com/noxdea/thuban/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-ruby.svg" alt="Ruby 3.1+">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#scope">Scope</a>
</p>

---

Thuban is a pure Ruby Git implementation for reading and writing local
repositories and transferring data with local, smart HTTP, or SSH remotes. Local
repository operations work directly with Git data without invoking the Git executable.

## Features

- Reads loose objects and packfiles, including deltified objects
- Resolves refs, branches, commits, trees, and blobs
- Reads the index and reports staged, worktree, and untracked changes
- Writes loose objects, index entries, refs, reflogs, trees, and commits
- Finds merge bases and performs reset, cherry-pick, revert, and stash operations
- Writes interoperable delta-free Git packfiles to any writable IO
- Discovers smart HTTP protocol v2 and v0 remote references
- Fetches smart HTTP packs into the local object database
- Authenticates smart HTTP with Basic, Bearer, callbacks, or Git credential helpers
- Pushes refs and packfiles with force-with-lease and atomic update support
- Discovers, fetches, and pushes SSH remotes through the system `ssh` executable
- Tracks line history across commits and renames with blame
- Writes files atomically and checks out branches with collision guards
- Supports linked worktrees and packed refs

## Installation

Add Thuban to your Gemfile:

```ruby
gem "thuban", "~> 0.3.0"
```

Then install it:

```sh
bundle install
```

Thuban requires Ruby 3.1 or later and targets SHA-1 Git repositories.

## Quick Start

Open the repository containing the current directory:

```ruby
require "thuban"

repo = Thuban::Repository.new(Dir.pwd)

puts repo.branch
puts repo.head

repo.status.each do |entry|
  puts "#{entry.code} #{entry.path}"
end
```

## Usage

### Read Repository Data

```ruby
repo.refs
repo.branches
repo.commit
repo.tree
repo.blob("README.md")
repo.index
repo.blame("README.md")
```

Pass a branch, tag, or object ID when reading another revision:

```ruby
repo.commit("v0.1.0")
repo.tree("main")
repo.blob("README.md", reference: "v0.1.0")
```

### Compare and Restore Changes

Thuban exposes staged and worktree content for explicit comparison with
[Porrima](https://github.com/noxdea/porrima):

```ruby
before = repo.staged_blob("README.md").to_s
after = repo.worktree_content("README.md").to_s
diff = Porrima.diff(before, after)

if (hunk = diff.hunks.first)
  repo.write("README.md", Porrima.revert(after, hunk))
end
```

### Write and Check Out

```ruby
repo.write("README.md", "updated contents\n")
repo.checkout("feature")
```

`Repository#write` rejects symlinks, preserves the file mode, and replaces the
file atomically. `Repository#checkout` requires a clean tracked worktree and
aborts on untracked or ignored collisions.

### Stage and Commit

Write a blob, add it to the index, then create a commit from the index:

```ruby
path = "README.md"
oid = repo.write_blob(File.binread(path))
index = repo.index
index.stage(path, oid, 0o100644, stat: File.stat(path))
index.write

author = Thuban::Signature.new(
  name: "Example Author",
  email: "author@example.com",
  time: Time.now
)
commit = repo.commit!(message: "Update README", author: author)
```

`Index#write` uses Git's `index.lock`, retains optional extensions as raw bytes,
and invalidates entry-dependent cache extensions after mutation. `unstage`
removes the stage-zero entry; stage the corresponding HEAD entry to restore a
tracked path. `conflicts` exposes stage 1/2/3 entries and `resolve` replaces
them with a stage-zero entry.

Create and update refs with optimistic old-OID checks:

```ruby
repo.create_branch("topic", repo.head)
repo.update_ref("refs/heads/topic", commit, old_oid: repo.head, message: "advance")
repo.reflog("topic") # raw Git reflog records
```

Ref mutations use `.lock` files and raise `Thuban::RefLockError` when a lock is
held or the expected old OID no longer matches. Loose updates override packed
refs, and deletion removes both forms.

### History and Stash

Use the same branch names, tags, or full object IDs accepted by the read API:

```ruby
base = repo.merge_base("main", "topic")
repo.reset(base, mode: :mixed) # :soft and :hard are also supported
picked = repo.cherry_pick("topic")
repo.revert(picked)

stash = repo.stash_push(message: "before refactor", include_untracked: true)
repo.stash_list # newest first, as Commit objects
repo.stash_pop if stash
```

Cherry-pick and revert require a clean tracked worktree and accept commits with
at most one parent. They merge non-overlapping text changes and detect remaining
three-way conflicts before changing files. Stash uses Git's standard commit and
reflog layout, retains staged state, and can include untracked files.
Worktree-changing operations reject submodules and untracked collisions rather
than silently deleting data.

### Write Packfiles

`Pack.write` accepts `[type, data]` object pairs, reports completed objects to an
optional block, and returns the hexadecimal pack checksum:

```ruby
objects = object_ids.map { |oid| repo.object(oid) }
File.open("out.pack", "wb") do |file|
  checksum = Thuban::Pack.write(file, objects) do |current, total|
    warn "#{current}/#{total}"
  end
end
```

The emitted PACK v2 stream stores complete compressed objects without delta
generation. It can be consumed by `git index-pack` and `git verify-pack`.
`Thuban::Pack.read_stream(io, repo.odb)` verifies and expands a received pack,
including offset and reference deltas, into the supplied object database.

### Inspect Remote References

Smart HTTP discovery prefers protocol v2 and falls back to v0 when necessary:

```ruby
connection = Thuban::Remote.open("https://example.com/project.git")
begin
  connection.refs.each do |ref|
    puts [ref.oid, ref.name, ref.symref_target, ref.peeled].compact.join(" ")
  end
ensure
  connection.close
end
```

Fetch selected object IDs directly, optionally providing local object IDs for
negotiation:

```ruby
wanted = connection.refs.find { |ref| ref.name == "refs/heads/main" }.oid
received_oids = connection.fetch(repo, wants: [wanted], haves: repo.refs.values.compact)
```

Authenticate with fixed Basic or Bearer credentials when appropriate:

```ruby
credentials = Thuban::Remote::Credentials.static(
  username: ENV.fetch("GIT_USERNAME"),
  password: ENV.fetch("GIT_PASSWORD")
)
connection = Thuban::Remote.open(remote_url, credentials: credentials)

token = Thuban::Remote::Credentials.bearer(token: ENV.fetch("GIT_TOKEN"))
connection = Thuban::Remote.open(remote_url, credentials: token)
```

For credentials that are selected or refreshed at runtime, return another
credential object from a callback. The callback receives the remote URL with no
embedded user information:

```ruby
credentials = Thuban::Remote::Credentials.callback do |url|
  Thuban::Remote::Credentials.bearer(token: token_for(url))
end
```

Use the normal configured Git credential helpers, or select a helper by name:

```ruby
credentials = Thuban::Remote::Credentials.helper
credentials = Thuban::Remote::Credentials.helper("store --file=/secure/path")
connection = Thuban::Remote.open(remote_url, credentials: credentials)
```

Helper lookup uses `git credential fill` with terminal prompting disabled and is
bounded by the connection timeout. Thuban never includes credentials, helper
output, response bodies, or remote URLs in transport errors. Credential objects
also redact their inspection output. URL-embedded credentials and HTTP redirects
remain rejected so an authorization header cannot be forwarded to another
origin.

For a repository with a normal `[remote "origin"]` configuration, the
high-level operation reads its fetch refspec and updates remote-tracking refs:

```ruby
repo.remotes # => {"origin" => "https://example.com/project.git"}
remote_refs = repo.fetch("origin")
```

Limit downloaded history or omit blobs while reporting bounded transfer and pack
progress:

```ruby
repo.fetch("origin", depth: 1) { |event| warn "#{event.phase}: #{event.bytes}" }
repo.fetch("origin", filter: "blob:none")
```

`depth:` accepts positive 32-bit integers and `filter:` currently accepts only
`"blob:none"`. Thuban negotiates only features advertised by the server. Shallow
boundaries are atomically maintained in Git's `shallow` file. For configured
remotes, partial fetches also set Git's `remote.<name>.promisor` and
`remote.<name>.partialclonefilter` keys, so the Git executable can retrieve an
omitted object later. Reading an omitted blob through Thuban raises `KeyError`;
automatic promisor-object retrieval remains the caller's responsibility.
Progress `bytes` are cumulative for `:pack` events and the current sideband
message size for `:remote` events, matching push progress.

Push one or more explicit refspecs. Normal updates must be fast-forward; use a
lease for a guarded rewrite, or `force: true` for an unconditional one:

```ruby
repo.push("origin", refspecs: "refs/heads/main:refs/heads/main")
repo.push("origin", refspecs: "refs/heads/topic:refs/heads/topic",
  lease: expected_remote_oid)
repo.push("origin", refspecs: [
  "refs/heads/main:refs/heads/main",
  "refs/tags/v1:refs/tags/v1"
], atomic: true) { |progress| warn "#{progress.phase}: #{progress.current}/#{progress.total}" }
```

Remote names, direct paths, `file://` URLs, HTTP(S), and SSH URLs are accepted.
At the lower level, `Connection#push` accepts `[ref, old_oid, new_oid]` updates;
the old object ID is an optimistic lease, and `nil` uses the advertised value.
Deletion uses an empty source refspec such as `:refs/heads/topic`.

Fetched packs are checksum-verified, bounded by byte/object/expanded-size
limits, and expanded through the existing object database. Redirects and
URL-embedded credentials remain rejected.

SSH remotes accept both standard URL and scp-like forms. Thuban invokes the
system SSH client without a local shell and uses `git-upload-pack` or
`git-receive-pack` over its
standard input and output:

```ruby
connection = Thuban::Remote.open("ssh://git@example.com/project.git")
connection = Thuban::Remote.open("git@example.com:project.git")
```

Pass `ssh:` as an argument array or safely parsed command string to select a
client and options. When omitted, `GIT_SSH_COMMAND` is parsed into arguments, or
`ssh` is used by default:

```ruby
connection = Thuban::Remote.open(remote_url, ssh: ["ssh", "-F", "/safe/config"])
```

SSH runs in batch mode, is bounded by `timeout:`, and discards stderr so remote
paths and server diagnostics are not copied into exceptions. User, host, port,
and path syntax is validated before process startup. Passwords in SSH URLs are
not supported; use normal SSH agents and configuration instead. SSH fetches use
the same shallow, partial, sideband progress, and pack validation paths as HTTP.

### Match Ignored Paths

Load Git's global excludes, `.git/info/exclude`, and nested `.gitignore` files.
Thuban also reads nested `.ignore` files for editor compatibility:

```ruby
ignore = Thuban::IgnoreMatcher.load(Dir.pwd)
ignore.ignored?("tmp/output.log")
ignore.ignored?("build", directory: true)
```

Pass root-relative or absolute files as `extra_files:` to apply them last, or
set `global: false` to skip `core.excludesFile` and the default global ignore
file. Thuban resolves the setting from system, XDG, home, and repository config
files, followed by an enabled worktree config. Included configs, line
continuations, and command-scoped overrides are not evaluated.

## Scope

The current write API covers loose objects, the index, refs, reflogs, commits,
guarded checkout, local history operations, stash, and delta-free pack output.
Thuban can fetch and push local, smart HTTP, and SSH remotes, including shallow
and blobless fetches. Merges, automatic retrieval of omitted promisor objects,
and pack delta generation are outside the current scope. It does not provide
its own diff algorithm; blame delegates line matching to Porrima through the
injectable `differ:` argument.

Support is limited to the index and pack formats covered by the test suite.
Submodule checkout and optional Git extensions outside that coverage are not
supported. Design decisions are recorded in [docs/adr](docs/adr/README.md).

## Development

```sh
bundle install
bundle exec rake
ruby tools/check_isolation.rb
bundle exec rbs -I sig -r porrima validate
gem build --strict thuban.gemspec
ruby bench/pack_write.rb --assert
ruby bench/ssh_fetch.rb --assert
```

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/noxdea/thuban).

## License

Thuban is available under the [MIT License](LICENSE.txt).
