# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "zlib"
require "thuban"
