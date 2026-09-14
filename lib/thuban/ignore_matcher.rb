# frozen_string_literal: true

module Thuban
  class IgnoreMatcher
    Rule = Struct.new(:base, :expression, :negated, :directory, keyword_init: true)

    def self.load(root, extra_files: [], global: true)
      root = File.realpath(root)
      raise ArgumentError, "ignore root must be a directory" unless File.directory?(root)

      matcher = new
      matcher = add_file(matcher, global_ignore_file) if global
      matcher = add_file(matcher, repository_exclude_file(root))
      matcher = discover(root, "", matcher)
      Array(extra_files).each do |file|
        absolute = File.expand_path(file, root)
        relative = absolute.delete_prefix(root + File::SEPARATOR)
        base = absolute == relative ? "" : File.dirname(relative)
        matcher = add_file(matcher, absolute, base == "." ? "" : base)
      end
      matcher
    end

    def initialize(rules = [])
      @rules = rules.freeze
    end

    def add(source, base: "")
      rules = source.lines.filter_map do |line|
        line = line.delete_suffix("\n").delete_suffix("\r")
        line = line.sub(/(?<!\\)(?:\\\\)*\K +\z/, "")
        next if line.empty? || line.start_with?("#")

        negated = line.start_with?("!")
        line = line[1..] if negated
        directory = line.end_with?("/")
        line = line.delete_suffix("/") if directory
        anchored = line.start_with?("/") || line.include?("/")
        line = line.delete_prefix("/")
        next if line.empty?

        expression = Regexp.new((anchored ? "\\A" : "(?:\\A|/)") + glob(line) + "\\z")
        Rule.new(base: base.delete_suffix("/"), expression: expression, negated: negated, directory: directory)
      rescue RegexpError
        nil
      end
      self.class.new(@rules + rules)
    end

    def ignored?(path, directory: false)
      parts = path.to_s.sub(%r{\A\./}, "").delete_suffix("/").split("/")
      parts.each_index do |index|
        candidate = parts[0..index].join("/")
        candidate_directory = index < parts.length - 1 || directory
        ignored = false
        @rules.each do |rule|
          next if rule.directory && !candidate_directory
          next unless rule.base.empty? || candidate.start_with?(rule.base + "/")

          local = rule.base.empty? ? candidate : candidate[(rule.base.length + 1)..]
          ignored = !rule.negated if rule.expression.match?(local)
        end
        return true if ignored
      end
      false
    end

    class << self
      private

      def add_file(matcher, path, base = "")
        path && File.file?(path) ? matcher.add(File.read(path, encoding: "UTF-8"), base: base) : matcher
      end

      def discover(root, directory, matcher)
        %w[.gitignore .ignore].each do |name|
          matcher = add_file(matcher, File.join(root, directory, name), directory)
        end
        Dir.children(File.join(root, directory)).sort.each do |name|
          next if name == ".git"

          relative = directory.empty? ? name : File.join(directory, name)
          absolute = File.join(root, relative)
          matcher = discover(root, relative, matcher) if File.directory?(absolute) && !File.symlink?(absolute) && !matcher.ignored?(relative, directory: true)
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          next
        end
        matcher
      end

      def global_ignore_file
        config = ENV["XDG_CONFIG_HOME"]
        config = File.join(Dir.home, ".config") if !config || config.empty?
        File.join(config, "git", "ignore")
      end

      def repository_exclude_file(root)
        git_dir = File.join(root, ".git")
        if File.file?(git_dir)
          value = File.read(git_dir).strip
          return unless value.start_with?("gitdir: ")

          git_dir = File.expand_path(value.delete_prefix("gitdir: "), root)
        end
        return unless File.directory?(git_dir)

        common = File.join(git_dir, "commondir")
        git_dir = File.expand_path(File.read(common).strip, git_dir) if File.file?(common)
        File.join(git_dir, "info", "exclude")
      end
    end

    private

    def glob(pattern)
      result = +""
      index = 0
      while index < pattern.length
        char = pattern[index]
        case char
        when "\\"
          index += 1
          result << Regexp.escape(pattern[index] || "\\")
        when "*"
          finish = index
          finish += 1 while pattern[finish + 1] == "*"
          if finish > index && (index.zero? || pattern[index - 1] == "/") && (finish == pattern.length - 1 || pattern[finish + 1] == "/")
            if pattern[finish + 1] == "/"
              result << "(?:[^/]+/)*"
              finish += 1
            else
              result << ".*"
            end
          else
            result << "[^/]*"
          end
          index = finish
        when "?"
          result << "[^/]"
        when "["
          cursor = index + 1
          cursor += 1 if ["!", "^"].include?(pattern[cursor])
          cursor += 1 if pattern[cursor] == "]"
          finish = nil
          while cursor < pattern.length
            if pattern[cursor, 2] == "[:" && (ending = pattern.index(":]", cursor + 2))
              cursor = ending + 2
              next
            end
            if pattern[cursor] == "]"
              finish = cursor
              break
            end
            cursor += pattern[cursor] == "\\" ? 2 : 1
          end
          if finish
            content = pattern[(index + 1)...finish].sub(/\A!/, "^")
            content = content.gsub(/(?<!\\)(.)-(.)/) { Regexp.last_match(1).ord > Regexp.last_match(2).ord ? Regexp.last_match(1) : Regexp.last_match(0) }
            result << "(?!/)[#{content}]"
            index = finish
          else
            result << "\\["
          end
        else
          result << Regexp.escape(char)
        end
        index += 1
      end
      result
    rescue RegexpError
      Regexp.escape(pattern)
    end
  end
end
