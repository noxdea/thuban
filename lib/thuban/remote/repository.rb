# frozen_string_literal: true

module Thuban
  class Repository
    def remotes
      remote_settings.transform_values { |settings| settings[:url] }.compact
    end

    def fetch(remote = "origin", refspecs: nil)
      settings = remote_settings[remote]
      url = settings&.fetch(:url, nil) || (remote if remote.to_s.match?(/\Ahttps?:\/\//))
      raise ArgumentError, "unknown remote: #{remote}" unless url

      specs = refspecs
      if specs.nil? && settings
        specs = settings[:fetch]
        specs = ["+refs/heads/*:refs/remotes/#{remote}/*"] if specs.empty?
      end
      specs = normalize_fetch_refspecs(specs)
      connection = Remote.open(url)
      advertised = connection.refs
      updates = select_fetch_refs(advertised, specs)
      wants = updates.map { |ref, _| ref.oid }.compact.uniq
      previous = updates.filter_map { |_, destination| [destination, resolve(destination)] if destination }.to_h
      unless wants.empty?
        haves = refs.values.compact.uniq.select { |oid| odb.exist?(oid) }
        connection.fetch(self, wants: wants, haves: haves)
        updates.each do |ref, destination|
          update_ref(destination, ref.oid, old_oid: previous.fetch(destination), message: "fetch #{remote}: #{ref.name}") if destination && ref.oid
        end
      end
      advertised
    ensure
      connection&.close
    end

    private

    def remote_settings
      result = {}
      current = nil
      File.foreach(File.join(common_dir, "config"), encoding: "UTF-8") do |line|
        stripped = line.strip
        if (match = stripped.match(/\A\[remote\s+"([^"\r\n]+)"\]\z/i))
          current = match[1]
          result[current] ||= {fetch: []}
        elsif stripped.start_with?("[")
          current = nil
        elsif current && (match = stripped.match(/\A(url|fetch)\s*=\s*(.*)\z/i))
          key = match[1].downcase.to_sym
          value = IgnoreMatcher.send(:parse_config_value, match[2])
          key == :fetch ? result[current][:fetch] << value : result[current][:url] = value
        end
      end
      result
    rescue Errno::ENOENT, Errno::EACCES
      {}
    end

    def normalize_fetch_refspecs(refspecs)
      return if refspecs.nil?

      refspecs = [refspecs] if refspecs.is_a?(String)
      raise TypeError, "refspecs must be enumerable" unless refspecs.respond_to?(:each)

      refspecs.map do |source|
        raise ArgumentError, "invalid fetch refspec" unless source.is_a?(String)

        source = source.delete_prefix("+")
        from, to = source.split(":", 2)
        valid = valid_refspec_name?(from) && (!to || valid_refspec_name?(to)) && from.count("*") <= 1 && to.to_s.count("*") <= 1 &&
          from.include?("*") == to.to_s.include?("*")
        raise ArgumentError, "invalid fetch refspec" unless valid

        [/\A#{Regexp.escape(from).sub("\\*", "(.*)")}\z/, to]
      end
    end

    def valid_refspec_name?(name)
      name.is_a?(String) && name.start_with?("refs/") && !name.end_with?("/", ".") &&
        !name.include?("..") && !name.include?("@{") && !name.match?(/[\x00-\x20\x7f~^:?\[\\]/) &&
        name.split("/").none? { |part| part.empty? || part.start_with?(".") || part.downcase.end_with?(".lock") }
    end

    def select_fetch_refs(advertised, refspecs)
      return advertised.map { |ref| [ref, nil] } if refspecs.nil?

      refspecs.flat_map do |pattern, destination|
        advertised.filter_map do |ref|
          match = pattern.match(ref.name)
          [ref, destination&.sub("*", match[1].to_s)] if match
        end
      end
    end
  end
end
