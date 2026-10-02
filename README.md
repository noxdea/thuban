<h1 align="center">Thuban</h1>

<p align="center">
  <strong>A pure Ruby Git implementation for local repositories and remote transfers.</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/thuban"><img src="https://img.shields.io/gem/v/thuban.svg" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/thuban"><img src="https://img.shields.io/gem/dt/thuban.svg" alt="Gem downloads"></a>
  <a href="https://github.com/noxdea/thuban/actions/workflows/main.yml"><img src="https://github.com/noxdea/thuban/actions/workflows/main.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="thuban.gemspec"><img src="https://img.shields.io/badge/Ruby-%3E%3D%203.1-cc342d.svg" alt="Ruby 3.1 or newer"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://noxdea.github.io/thuban/">Website</a> ·
  <a href="https://noxdea.github.io/thuban/guide/">User Guide</a> ·
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a>
</p>

---

Thuban lets Ruby applications inspect Git history, stage and commit changes,
and transfer objects and refs with remotes. Local repository operations read
and write Git data directly, without invoking the Git executable. It uses
[Porrima](https://github.com/noxdea/porrima) for line matching in blame and
for composing diffs in your application.

## Features

- Read loose and packed objects, including deltas, refs, commits, trees, and blobs.
- Inspect the index, staged and worktree changes, ignored paths, and line history across renames.
- Write objects, stage files, create commits, and update refs and reflogs with locks and old-OID checks.
- Check out branches, reset, cherry-pick, revert, resolve index conflicts, and stash changes.
- Fetch and push local, smart HTTP, and SSH remotes; pull fast-forward updates.
- Use Basic, Bearer, callback, or Git credential helper authentication for HTTP.
- Fetch shallow or blobless history and report transfer progress with cancellation support.
- Write interoperable delta-free packfiles and work with linked worktrees and packed refs.

## Installation

Add Thuban to your Gemfile:

```ruby
gem "thuban", "~> 0.6.0"
```

Then run `bundle install`. To install it directly:

```sh
gem install thuban
```

Thuban requires Ruby 3.1 or newer and supports SHA-1 Git repositories.
Local read and write operations need no Git executable. Local remote transfers
need `git-upload-pack` and `git-receive-pack`; SSH remotes need the system
`ssh` client, and Git credential helpers need `git`. Smart HTTP transfers use
Ruby's standard library.

## Quick start

Run this from an existing Git worktree:

```ruby
require "thuban"

repo = Thuban::Repository.new(Dir.pwd)

puts repo.branch
puts repo.head

repo.status.each do |entry|
  puts "#{entry.code} #{entry.path}"
end

repo.each_commit(limit: 10).each do |commit|
  puts "#{commit.oid[0, 7]} #{commit.message.lines.first.to_s.chomp}"
end
```

Repository discovery walks up from the supplied directory. Status codes use
two columns for index and worktree changes, such as ` M` for an unstaged
modification or `??` for an untracked file. History reads require a positive
`limit`.

## Usage

Read a committed file, the index version, or its current worktree content:

```ruby
repo.blob("README.md")
repo.blob("README.md", reference: "main")
repo.staged_blob("README.md")
repo.worktree_content("README.md")
repo.blame("README.md")
```

Stage an existing regular file, then commit the index:

```ruby
path = "README.md"
absolute = repo.worktree_path(path)
stat = File.stat(absolute)
mode = (stat.mode & 0o100).positive? ? 0o100755 : 0o100644

index = repo.index
index.stage(path, repo.write_blob(File.binread(absolute)), mode, stat: stat)
index.write

oid = repo.commit!(message: "Update README", author: repo.signature)
puts oid
```

`repo.signature` reads the author environment variables, then `user.name` and
`user.email` from Git configuration. Set an identity before committing. The
[writing guide](https://noxdea.github.io/thuban/guide/#writing) also covers
amending commits, restoring index entries, and resolving conflicts.

For a repository with an `origin` remote:

```ruby
repo.fetch("origin")
repo.push("origin", refspecs: "refs/heads/main:refs/heads/main")
repo.pull("origin", branch: "main")
```

Fetch updates configured remote-tracking refs. Push requires explicit
refspecs and supports leases and atomic updates. Pull requires a clean
tracked worktree and applies only fast-forward updates. See
[remote transfers](https://noxdea.github.io/thuban/guide/#remotes) for
authentication, shallow fetches, SSH options, progress, and cancellation.

## Scope and limits

Thuban is a library for existing repositories. It does not expose `init`,
`clone`, a command-line interface, or a general merge operation. SHA-256
repositories, submodule checkout, automatic retrieval of omitted promisor
objects, and pack delta generation are outside the current scope.

Worktree operations reject unsupported submodules and file collisions.
Supported index and pack formats are covered by the test suite. See the
[limits and error handling guide](https://noxdea.github.io/thuban/guide/#limits)
before integrating write or transfer operations.

## Documentation

- [User Guide](https://noxdea.github.io/thuban/guide/)
- [Repository data and status](https://noxdea.github.io/thuban/guide/#reading)
- [Writing and conflict resolution](https://noxdea.github.io/thuban/guide/#writing)
- [Remote transfers and authentication](https://noxdea.github.io/thuban/guide/#remotes)
- [Development](https://noxdea.github.io/thuban/guide/#development)
- [Architecture decisions](docs/adr/README.md)
- [Type signatures](sig/thuban.rbs)
- [Changelog](CHANGELOG.md)

## Development

```sh
bundle install
bundle exec rake
ruby tools/check_isolation.rb
bundle exec rbs -I sig -r porrima validate
gem build --strict thuban.gemspec
```

Bug reports and pull requests are welcome on
[GitHub](https://github.com/noxdea/thuban).

## License

Thuban is released under the [MIT License](LICENSE.txt).
