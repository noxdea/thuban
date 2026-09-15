<h1 align="center">Thuban</h1>

<p align="center">
  <strong>A pure Ruby implementation for local Git repositories</strong>
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
repositories. It works directly with repository data without invoking the Git
executable.

## Features

- Reads loose objects and packfiles, including deltified objects
- Resolves refs, branches, commits, trees, and blobs
- Reads the index and reports staged, worktree, and untracked changes
- Writes loose objects, index entries, refs, reflogs, trees, and commits
- Finds merge bases and performs reset, cherry-pick, revert, and stash operations
- Writes interoperable delta-free Git packfiles to any writable IO
- Tracks line history across commits and renames with blame
- Writes files atomically and checks out branches with collision guards
- Supports linked worktrees and packed refs

## Installation

Add Thuban to your Gemfile:

```ruby
gem "thuban", "~> 0.2.0"
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
at most one parent. They detect path-level three-way conflicts before changing
files. Stash uses Git's standard commit and reflog layout, retains staged state,
and can include untracked files. Worktree-changing operations reject submodules
and untracked collisions rather than silently deleting data.

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
Thuban does not yet perform network operations, merges, pack delta generation,
or streaming pack ingestion. It does not provide its own diff algorithm; blame
delegates line matching to Porrima through the injectable `differ:` argument.

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
```

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/noxdea/thuban).

## License

Thuban is available under the [MIT License](LICENSE.txt).
