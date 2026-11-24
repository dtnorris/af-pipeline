# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
$LOAD_PATH.unshift File.expand_path("../lib",__dir__)
require "af_data_pipeline"
