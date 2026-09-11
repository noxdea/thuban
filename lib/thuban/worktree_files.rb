# frozen_string_literal: true

module Thuban
  class WorktreeFiles
    include Enumerable

    def initialize(root, common_dir)
      @root = File.realpath(root)
      @common_dir = common_dir
    end

    def each(&block)
      return enum_for(__method__) unless block

      rules = IgnoreMatcher.new
      exclude = File.join(@common_dir, "info", "exclude")
      rules = rules.add(File.read(exclude), base: "") if File.file?(exclude)
      walk("", rules, {}, &block)
      self
    end

    private

    def walk(directory, rules, visited, &block)
      stat = File.stat(path(directory))
      return if visited[[stat.dev, stat.ino]]

      visited[[stat.dev, stat.ino]] = true
      %w[.gitignore .ignore].each do |name|
        source = path(directory.empty? ? name : File.join(directory, name))
        rules = rules.add(File.read(source, encoding: "UTF-8"), base: directory) if File.file?(source)
      end
      Dir.children(path(directory)).sort.each do |name|
        next if name == ".git"

        relative = directory.empty? ? name : File.join(directory, name)
        absolute = path(relative)
        entry = File.lstat(absolute)
        if entry.symlink?
          yield relative unless rules.ignored?(relative)
        elsif !rules.ignored?(relative, directory: entry.directory?)
          if entry.directory?
            walk(relative, rules, visited, &block)
          elsif entry.file?
            yield relative
          end
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        next
      end
    end

    def path(relative) = File.expand_path(relative, @root)
  end
end
