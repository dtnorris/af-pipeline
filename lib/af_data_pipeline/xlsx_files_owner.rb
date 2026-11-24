# frozen_string_literal: true

require "pathname"

# Load one selected public catalog owner. An explicit root is authoritative:
# missing/incompatible code must never fall back to an installed or sibling copy.
selected_root = ENV["AF_XLSX_FILES_ROOT"]
if selected_root
  raise LoadError, "AF_XLSX_FILES_ROOT must be a nonblank absolute directory" if selected_root.strip.empty? || !Pathname.new(selected_root).absolute?
  entry = File.join(selected_root, "lib", "af_xlsx_files.rb")
  raise LoadError, "AF_XLSX_FILES_ROOT has no public entrypoint: #{entry}" unless File.file?(entry)
  selected_lib = File.realpath(File.dirname(entry))
  loaded_owner = $LOADED_FEATURES.find { |path| path.end_with?("/af_xlsx_files.rb") }
  if loaded_owner && File.realpath(loaded_owner) != File.realpath(entry)
    raise LoadError, "another af-xlsx-files owner is already loaded: #{loaded_owner}"
  end
  require File.realpath(entry)
  foreign = $LOADED_FEATURES.select { |path| path.include?("/af_xlsx_files/") }.reject do |path|
    File.realpath(path).start_with?(selected_lib + File::SEPARATOR)
  end
  raise LoadError, "af-xlsx-files loaded outside the selected root: #{foreign.join(', ')}" unless foreign.empty?
else
  raise LoadError, "set AF_XLSX_FILES_ROOT to the pinned public workbook owner"
end
unless defined?(AfXlsxFiles::API_VERSION) && AfXlsxFiles::API_VERSION == "0.1"
  raise LoadError, "af-xlsx-files API 0.1 is required"
end
