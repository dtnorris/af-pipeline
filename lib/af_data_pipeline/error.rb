# frozen_string_literal: true

require_relative "xlsx_files_owner"

module AfDataPipeline
  class Error < StandardError; end
  class ValidationError < Error; end
  class UnsafeArchiveError < Error; end

  # Translate catalog-owner failures at pipeline entry points without changing
  # either library's named exceptions, messages, backtraces or rescue hierarchy.
  module XlsxFilesErrors
    # Return forwarding wrappers for the named methods. Owner failures become
    # pipeline errors; results, blocks and unrelated exceptions pass through.
    def self.wrap(*method_names)
      Module.new do
        method_names.each do |method_name|
          define_method(method_name) do |*arguments, **keywords, &block|
            super(*arguments, **keywords, &block)
          rescue AfXlsxFiles::ValidationError => error
            raise ValidationError, error.message, error.backtrace
          rescue AfXlsxFiles::Error => error
            raise Error, error.message, error.backtrace
          end
        end
      end
    end
  end
end
