# frozen_string_literal: true
module AfDataPipeline
  class Scanner
    Entry = Struct.new(:relative_path, :absolute_path, :bytes, :sha256, :extension, keyword_init: true) do
      def to_h
        {"relative_path"=>relative_path,"bytes"=>bytes,"sha256"=>sha256,"extension"=>extension}
      end
    end
    def initialize(root:, single_file: nil)
      @root=File.expand_path(root); @single_file=single_file && File.expand_path(single_file)
    end
    def scan(progress: nil, progress_every: 500)
      paths = @single_file ? [@single_file] : Dir.glob(File.join(@root,"**","*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }
      paths = paths.reject { |path| ignored_packaging_artifact?(path) }.sort
      progress&.call(phase: :scan, current: 0, total: paths.length)
      entries = paths.each_with_index.map do |path, index|
        entry = build_entry(path)
        current = index + 1
        if current == paths.length || (progress_every.positive? && (current % progress_every).zero?)
          progress&.call(phase: :scan, current:, total: paths.length)
        end
        entry
      end
      entries
    end
    private
    def ignored_packaging_artifact?(path)
      relative_path = Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
      parts = relative_path.split(File::SEPARATOR)
      parts.include?("__MACOSX") || parts.any? { |part| part.start_with?("._") || part == ".DS_Store" }
    end
    def build_entry(path)
      Entry.new(relative_path: Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s, absolute_path: path, bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest, extension: File.extname(path).downcase)
    end
  end
end
