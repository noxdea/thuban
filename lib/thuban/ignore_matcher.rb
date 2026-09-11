# frozen_string_literal: true

module Thuban
  class IgnoreMatcher
    Rule = Struct.new(:base, :expression, :negated, :directory, keyword_init: true)

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
      ignored = false
      @rules.each do |rule|
        next if rule.directory && !directory
        next unless rule.base.empty? || path.start_with?(rule.base + "/")

        local = rule.base.empty? ? path : path[(rule.base.length + 1)..]
        ignored = !rule.negated if rule.expression.match?(local)
      end
      ignored
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
