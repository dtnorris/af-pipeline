# frozen_string_literal: true

require_relative "source_markdown_owner"

module AfDataPipeline
  # Preserve caller identity validation while MD owns its implementation.
  module SourceIdentity
    module_function

    # Return the canonical identity from value, or raise the caller's error class.
    def validate!(value, error_class:)
      SourceMarkdownOwner.load!(error_class: error_class)::SourceIdentity.validate!(value, error_class: error_class)
    end

    # Return whether value resembles a source filename/path; invalid owner raises ValidationError.
    def path_like?(value)
      SourceMarkdownOwner.load!(error_class: ValidationError)::SourceIdentity.path_like?(value)
    end
  end
end
