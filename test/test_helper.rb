# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
ENV["GIT_CONFIG_COUNT"] = "1"
ENV["GIT_CONFIG_KEY_0"] = "maintenance.auto"
ENV["GIT_CONFIG_VALUE_0"] = "false"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "zlib"
require "thuban"
