<h1 align="center">Thuban</h1>

<p align="center">
  <strong>A pure Ruby reader for local Git repositories</strong>
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

Thuban is a pure Ruby Git repository reader for objects, packs, index,
status, blame, and guarded checkout. It works directly with local repository
data without invoking the Git executable.

## Features

- Reads loose objects and packfiles, including deltified objects
- Resolves refs, branches, commits, trees, and blobs
- Reads the index and reports staged, worktree, and untracked changes
- Tracks line history across commits and renames with blame
- Writes files atomically and checks out branches with collision guards
- Supports linked worktrees and packed refs

## Installation

Add Thuban to your Gemfile:

```ruby
gem "thuban", "~> 0.1.0"
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

## Scope

Thuban does not perform network operations such as fetch or push, rewrite
history, or provide its own diff algorithm. Blame delegates line matching to
Porrima through the injectable `differ:` argument.

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
```

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/noxdea/thuban).

## License

Thuban is available under the [MIT License](LICENSE.txt).
