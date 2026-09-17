# frozen_string_literal: true

module Thuban
  class Repository
    def remotes
      remote_settings.transform_values { |settings| settings[:url] }.compact
    end

    def fetch(remote = "origin", refspecs: nil, depth: nil, filter: nil, credentials: nil, ssh: nil, timeout: 30, cancelled: nil)
      depth = Remote::Protocol.validate_depth(depth)
      filter = Remote::Protocol.validate_filter(filter)
      validate_cancelled(cancelled)
      settings = remote_settings[remote]
      direct = direct_remote?(remote)
      url = settings&.fetch(:url, nil) || (remote if direct)
      raise ArgumentError, "unknown remote: #{remote}" unless url
      url = normalize_remote_url(url)

      specs = refspecs
      if specs.nil? && settings
        specs = settings[:fetch]
        specs = ["+refs/heads/*:refs/remotes/#{remote}/*"] if specs.empty?
      end
      specs = normalize_fetch_refspecs(specs)
      check_cancellation!(cancelled)
      connection = Remote.open(url, credentials: credentials, ssh: ssh, timeout: timeout)
      advertised, updates, previous, publish = with_transfer(connection, cancelled) do |check_cancelled|
        advertised = connection.refs
        check_cancelled.call
        updates = select_fetch_refs(advertised, specs)
        wants = updates.map { |ref, _| ref.oid }.compact.uniq
        previous = updates.filter_map { |_, destination| [destination, resolve(destination)] if destination }.to_h
        unless wants.empty?
          haves = refs.values.compact.uniq.select { |oid| odb.exist?(oid) }
          connection.fetch(self, wants: wants, haves: haves, depth: depth, filter: filter) do |progress|
            yield progress if block_given?
            check_cancelled.call
          end
          check_cancelled.call
        end
        check_cancelled.call
        [advertised, updates, previous, !wants.empty?]
      end
      check_cancellation!(cancelled)
      if publish
        record_promisor(remote, filter) if filter && settings
        updates.each do |ref, destination|
          update_ref(destination, ref.oid, old_oid: previous.fetch(destination), message: "fetch #{remote}: #{ref.name}") if destination && ref.oid
        end
      end
      advertised
    end

    def push(remote = "origin", refspecs:, force: false, lease: nil, atomic: false,
      credentials: nil, ssh: nil, timeout: 30, cancelled: nil)
      validate_cancelled(cancelled)
      settings = remote_settings[remote]
      direct = direct_remote?(remote)
      url = settings&.fetch(:pushurl, nil) || settings&.fetch(:url, nil) || (remote if direct)
      raise ArgumentError, "unknown remote: #{remote}" unless url
      url = normalize_remote_url(url)
      raise ArgumentError, "force must be true or false" unless [true, false].include?(force)
      raise ArgumentError, "atomic must be true or false" unless [true, false].include?(atomic)

      check_cancellation!(cancelled)
      connection = Remote.open(url, credentials: credentials, ssh: ssh, timeout: timeout)
      with_transfer(connection, cancelled) do |check_cancelled|
        advertised = connection.send(:receive_refs)
        check_cancelled.call
        updates = push_updates(refspecs, force: force, lease: lease, advertised: advertised)
        result = connection.push(self, updates, atomic: atomic) do |progress|
          yield progress if block_given?
          check_cancelled.call
        end
        check_cancelled.call
        result
      end
    end

    def pull(remote = "origin", branch: nil, ff_only: true, credentials: nil, ssh: nil, timeout: 30, cancelled: nil, &progress)
      raise ArgumentError, "only fast-forward pulls are supported" unless ff_only == true
      validate_cancelled(cancelled)
      check_cancellation!(cancelled)
      raise ArgumentError, "bare repository has no worktree" unless root
      local_branch = self.branch
      raise ArgumentError, "cannot pull with a detached HEAD" unless local_branch
      remote_branch = branch || local_branch
      raise ArgumentError, "invalid remote branch" unless valid_refspec_name?("refs/heads/#{remote_branch}")
      ensure_clean_tracked_state!
      current = head

      settings = remote_settings[remote]
      destination = settings && "refs/remotes/#{remote}/#{remote_branch}"
      spec = "refs/heads/#{remote_branch}:#{destination}"
      spec = "refs/heads/#{remote_branch}" unless destination
      advertised = fetch(remote, refspecs: spec, credentials: credentials, ssh: ssh, timeout: timeout,
        cancelled: cancelled, &progress)
      check_cancellation!(cancelled)
      target = advertised.find { |ref| ref.name == "refs/heads/#{remote_branch}" }&.oid
      raise TransportError, "remote branch not found: #{remote_branch}" unless target
      return target if current == target
      raise TransportError, "pull is not a fast-forward" if current && merge_base(current, target) != current

      check_cancellation!(cancelled)
      RefStore.new(self).update("HEAD", target, old_oid: current, message: "pull #{remote} #{remote_branch}: fast-forward") do
        raise RefLockError, "HEAD changed during pull" unless self.branch == local_branch
        ensure_clean_tracked_state!
        check_cancellation!(cancelled)
        replace_repository_state(tree(target), tree(target))
      end
    end

    private

    def validate_cancelled(cancelled)
      return if cancelled.nil?

      callable = cancelled.respond_to?(:call) && cancelled.method(:call)
      valid = callable && callable.parameters.none? { |kind, _| %i[req keyreq].include?(kind) }
      raise TypeError, "cancelled must be a zero-argument callable" unless valid
    end

    def check_cancellation!(cancelled)
      raise Cancelled, "transfer cancelled" if cancelled&.call
    end

    def with_transfer(connection, cancelled)
      state = {done: false, cancelled: false}
      lock = Mutex.new
      check = lambda do
        requested = lock.synchronize { state[:cancelled] } || cancelled&.call
        lock.synchronize { state[:cancelled] = true } if requested
        raise Cancelled, "transfer cancelled" if requested
      end
      check.call
      watcher = if cancelled
        Thread.new do
          loop do
            sleep 0.01
            break if lock.synchronize { state[:done] }
            next unless cancelled.call

            lock.synchronize { state[:cancelled] = true }
            connection.close
            break
          end
        end
      end
      yield check
    rescue TransportError
      raise Cancelled, "transfer cancelled" if lock&.synchronize { state[:cancelled] }

      raise
    ensure
      lock&.synchronize { state[:done] = true }
      watcher&.join
      connection&.close
    end

    def direct_remote?(remote)
      value = remote.to_s
      value.match?(/\A(?:https?|ssh|file):\/\//i) || (!value.include?("://") && value.include?(":")) ||
        value.start_with?("/", "./", "../", "~") || File.exist?(File.expand_path(value, root || common_dir))
    end

    def normalize_remote_url(url)
      local = !url.include?("://") && (url.start_with?("/", "./", "../", "~") ||
        !url.include?(":") || url.match?(/\A[A-Za-z]:[\\\/]/))
      local ? File.expand_path(url, root || common_dir) : url
    end

    def remote_settings
      result = {}
      current = nil
      File.foreach(File.join(common_dir, "config"), encoding: "UTF-8") do |line|
        stripped = line.strip
        if (match = stripped.match(/\A\[remote\s+"([^"\r\n]+)"\]\z/i))
          current = match[1]
          result[current] ||= {fetch: [], push: []}
        elsif stripped.start_with?("[")
          current = nil
        elsif current && (match = stripped.match(/\A(url|pushurl|fetch|push)\s*=\s*(.*)\z/i))
          key = match[1].downcase.to_sym
          value = IgnoreMatcher.send(:parse_config_value, match[2])
          %i[fetch push].include?(key) ? result[current][key] << value : result[current][key] = value
        end
      end
      result
    rescue Errno::ENOENT, Errno::EACCES
      {}
    end

    def record_promisor(remote, filter)
      path = File.join(common_dir, "config")
      raise ArgumentError, "unsafe Git config" if File.symlink?(path) || File.symlink?(path + ".lock")
      lock = File.open(path + ".lock", File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
      lines = File.readlines(path, mode: "rb")
      start = lines.index { |line| line.strip.match?(/\A\[remote\s+"#{Regexp.escape(remote)}"\]\z/i) }
      raise RefLockError, "remote configuration changed during fetch" unless start

      finish = ((start + 1)...lines.length).find { |index| lines[index].lstrip.start_with?("[") } || lines.length
      body = lines[(start + 1)...finish].reject { |line| line.strip.match?(/\A(?:promisor|partialclonefilter)\s*=/i) }
      body[-1] = body[-1] + "\n" if body.any? && !body[-1].end_with?("\n")
      body << "\tpromisor = true\n" << "\tpartialclonefilter = #{filter}\n"
      lock.chmod(File.stat(path).mode & 0o777)
      lock.write((lines[0..start] + body + lines[finish..].to_a).join)
      lock.flush
      lock.fsync
      lock.close
      File.rename(lock.path, path)
    rescue Errno::EEXIST
      raise RefLockError, "Git config is locked"
    ensure
      lock&.close unless lock&.closed?
      File.unlink(lock.path) if lock && File.exist?(lock.path)
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

    def push_updates(refspecs, force:, lease:, advertised:)
      specs = refspecs.is_a?(String) ? [refspecs] : refspecs
      raise TypeError, "refspecs must be enumerable" unless specs.respond_to?(:each)

      entries = specs.flat_map { |spec| expand_push_refspec(spec, force: force) }
      raise ArgumentError, "at least one push refspec is required" if entries.empty?
      expected = push_leases(lease, entries)
      entries.map do |entry|
        current = advertised.find { |ref| ref.name == entry[:destination] }&.oid || Remote::Connection::ZERO_OID
        old_oid = expected.fetch(entry[:destination], current)
        raise TransportError, "remote reference changed: #{entry[:destination]}" unless old_oid == current
        unless entry[:forced] || expected.key?(entry[:destination]) || entry[:new_oid] == Remote::Connection::ZERO_OID
          if current != Remote::Connection::ZERO_OID && current != entry[:new_oid] && (!entry[:destination].start_with?("refs/heads/") ||
              !odb.exist?(current) || merge_base(current, entry[:new_oid]) != current)
            raise TransportError, "non-fast-forward push requires force or lease: #{entry[:destination]}"
          end
        end
        [entry[:destination], old_oid, entry[:new_oid]]
      end
    end

    def expand_push_refspec(spec, force:)
      raise ArgumentError, "invalid push refspec" unless spec.is_a?(String)

      forced = force || spec.start_with?("+")
      source, destination = spec.delete_prefix("+").split(":", 2)
      valid = destination && valid_refspec_name?(destination) && source.count("*") <= 1 && destination.count("*") <= 1 &&
        source.include?("*") == destination.include?("*")
      raise ArgumentError, "invalid push refspec" unless valid

      if source.empty?
        raise ArgumentError, "wildcard deletion is not supported" if destination.include?("*")
        return [{destination: destination, new_oid: Remote::Connection::ZERO_OID, forced: forced}]
      end
      if source.include?("*")
        raise ArgumentError, "invalid push refspec" unless valid_refspec_name?(source)
        pattern = /\A#{Regexp.escape(source).sub("\\*", "(.*)")}\z/
        return refs.filter_map do |name, oid|
          match = pattern.match(name)
          {destination: destination.sub("*", match[1]), new_oid: oid, forced: forced} if match && oid
        end
      end

      new_oid = resolve(source)
      raise ArgumentError, "unknown push source: #{source}" unless new_oid && odb.exist?(new_oid)

      [{destination: destination, new_oid: new_oid, forced: forced}]
    end

    def push_leases(lease, entries)
      return {} if lease.nil?
      if lease.is_a?(String)
        raise ArgumentError, "a scalar lease requires one refspec" unless entries.length == 1
        return {entries.first[:destination] => Remote::Protocol.validate_oid(lease)}
      end
      raise TypeError, "lease must be an object ID or a ref-to-object-ID Hash" unless lease.is_a?(Hash)

      lease.to_h do |name, oid|
        raise ArgumentError, "lease contains an invalid reference" unless valid_refspec_name?(name)
        [name, Remote::Protocol.validate_oid(oid)]
      end.tap do |leases|
        missing = entries.map { |entry| entry[:destination] } - leases.keys
        raise ArgumentError, "lease is missing a push destination" unless missing.empty?
      end
    end
  end
end
