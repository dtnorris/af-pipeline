# frozen_string_literal: true
module AfDataPipeline
  class SourceWorkspace
    attr_reader :source_path, :root, :source_type
    def initialize(source_path)
      @source_path = File.expand_path(source_path)
      raise Error, "source does not exist: #{@source_path}" unless File.exist?(@source_path)
    end
    def with_root
      if File.directory?(source_path)
        @source_type = "directory"; @root = source_path; yield root
      elsif File.extname(source_path).downcase == ".zip"
        @source_type = "zip"
        Dir.mktmpdir("af-data-pipeline-") do |tmpdir|
          extract_zip!(source_path, tmpdir); @root = tmpdir; yield root
        end
      else
        @source_type = "file"; @root = File.dirname(source_path); yield source_path
      end
    end
    private
    def extract_zip!(zip_path, destination)
      destination = File.expand_path(destination)
      Zip::File.open(zip_path) do |archive|
        archive.each do |entry|
          next if entry.directory?
          target = File.expand_path(entry.name, destination)
          unless target == destination || target.start_with?(destination + File::SEPARATOR)
            raise UnsafeArchiveError, "unsafe ZIP entry escapes extraction root: #{entry.name.inspect}"
          end
          FileUtils.mkdir_p(File.dirname(target))
          entry.get_input_stream do |input|
            File.open(target, "wb") { |output| IO.copy_stream(input, output) }
          end
        end
      end
    rescue Zip::Error => e
      raise Error, "cannot read ZIP #{zip_path}: #{e.message}"
    end
  end
end
