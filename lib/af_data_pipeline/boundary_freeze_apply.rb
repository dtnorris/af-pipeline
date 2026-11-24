# frozen_string_literal: true

require_relative "private_data_root"

require_relative "error"

module AfDataPipeline
  # Retains freeze/source admission and delegates the sole construction kernel
  # to XL. Public paths, reports, errors and inherited read helpers stay compatible.
  class BoundaryFreezeApply < AfXlsxFiles::BoundaryFreezeApply
    prepend XlsxFilesErrors.wrap(:apply!)
    singleton_class.prepend XlsxFilesErrors.wrap(:plan!, :verify!, :verify_bound!,
      :derive_successor_paths)

    # Preserve direct pipeline helper rescues without changing standalone XL.
    class Worksheet < AfXlsxFiles::BoundaryFreezeApply::Worksheet
      PIPELINE_ERRORS = XlsxFilesErrors.wrap(*superclass.public_instance_methods(false))
      prepend PIPELINE_ERRORS
      prepend XlsxFilesErrors.wrap(:initialize)
    end

    class Workbook < AfXlsxFiles::BoundaryFreezeApply::Workbook
      prepend XlsxFilesErrors.wrap(*superclass.public_instance_methods(false), :initialize)

      # Return the owner's parsed sheet with pipeline exception translation.
      def sheet(part)
        super&.extend(Worksheet::PIPELINE_ERRORS)
      end
    end

    # Verify with the owner's constructor and independently bound inputs;
    # the pipeline adapter constructor accepts workflow options instead.
    def self.verify_bound!(**inputs)
      AfXlsxFiles::BoundaryFreezeApply.verify_bound!(**inputs)
    end

    # Validate actual PL source/freeze evidence, then construct an unaccepted
    # successor through XL. Returns Result; admission/integrity errors propagate.
    def self.apply!(freeze_path:, source_root:, amc_path:, publisher:, output_path:,
                    report_path: nil, registry_path: nil, progress: nil)
      new(freeze_path:, source_root:, amc_path:, publisher:, output_path:,
          report_path:, registry_path:, progress:).apply!
    end

    # Reconstruct allocation from freshly admitted records without publication.
    # Returns the existing plan mapping; invalid PL/XL bindings raise ValidationError.
    def self.plan!(freeze_path:, source_root:, amc_path:, publisher:, registry_path: nil)
      validation = BoundaryFreeze.validate!(freeze_path:, source_root:, amc_path:, registry_path:)
      AfXlsxFiles::BoundaryFreezeApply.plan!(freeze_path:, source_root:, amc_path:, publisher:, registry_path:,
        artifact: validation.artifact, freeze_sha256: validation.sha256,
        amc_sha256: validation.artifact.fetch("base_amc").fetch("sha256"))
    end

    # Store the original public options; only PL may admit source semantics.
    # Returns an adapter; path/value errors are reported on apply! as before.
    def initialize(freeze_path:, source_root:, amc_path:, publisher:, output_path:,
                   report_path:, registry_path:, progress:)
      @options = {freeze_path:, source_root:, amc_path:, publisher:, output_path:,
                  report_path:, registry_path:, progress:}
    end

    # Run real PL admission and XL integrity. No report or PASS flag grants
    # approval; returns Result, propagating the original validation error class.
    def apply!
      PrivateDataRoot.external_store!(File.dirname(File.expand_path(@options.fetch(:output_path))))
      if (report = @options[:report_path])
        PrivateDataRoot.external_store!(File.dirname(File.expand_path(report)))
      end
      validation = BoundaryFreeze.validate!(**@options.slice(:freeze_path, :source_root, :amc_path, :registry_path))
      AfXlsxFiles::BoundaryFreezeApply.apply!(**@options, artifact: validation.artifact,
        freeze_sha256: validation.sha256, amc_sha256: validation.artifact.fetch("base_amc").fetch("sha256"))
    end
  end
end
