# Thuban

Thuban is a pure Ruby reader for local Git repositories. It reads SHA-1
objects, packfiles, refs, commits, trees, blobs, indexes, status, and blame,
and supports a guarded checkout.

## Installation

```ruby
gem "thuban", "~> 0.1.0"
```

## Usage

```ruby
require "thuban"

repo = Thuban::Repository.new(Dir.pwd)
repo.head
repo.branch
repo.blob("README.md")
repo.staged_blob("README.md")
repo.worktree_content("README.md")
repo.status
repo.blame("README.md")
```

Text comparison stays explicit:

```ruby
diff = Porrima.diff(
  repo.staged_blob("README.md").to_s,
  repo.worktree_content("README.md").to_s
)

hunk = diff.hunks.first
repo.write("README.md", Porrima.revert(repo.worktree_content("README.md"), hunk)) if hunk
```

`Repository#write` rejects symlinks, preserves the file mode, and replaces the
file atomically. `Repository#checkout` requires a clean tracked worktree and
aborts on untracked collisions.

## Scope

Thuban does not implement a diff algorithm; blame delegates line matching to
Porrima through the injectable `differ:` argument. It does not perform network
operations such as fetch or push. Writes are limited to atomic worktree
replacement and checkout; it does not rewrite history.

Thuban targets SHA-1 repositories. It supports the index and pack formats
covered by its test suite, not every optional Git extension. Submodule checkout
is deliberately excluded.

## Development

```sh
bundle install
bundle exec rake
ruby tools/check_isolation.rb
bundle exec rbs -I sig -r porrima validate
gem build --strict thuban.gemspec
```

## License

Thuban is available under the MIT License.
