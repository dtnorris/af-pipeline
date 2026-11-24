# frozen_string_literal: true

require_relative "private_data_root"
require_relative "source_markdown_owner"

module AfDataPipeline
  module BoundaryFreeze
    SCHEMA_VERSION = "af-boundary-freeze/v0.1"
    SOURCE_REGISTRY_SCHEMA_VERSION = "adventurefinder-source-registry/v0.1"
    SHA256_RE = /\A[0-9a-f]{64}\z/
    ADV_ID_RE = /\AADV-\d{4,}\z/
    HANDOFF_HEADER = <<~TEXT.freeze
      # AdventureFinder frontier-review handoff.
      # Do not edit source/base_amc provenance fields or assign new Adventure IDs.
      # Frontier review may populate records and approval, then set state to frozen.
      # Contract: docs/BOUNDARY_FREEZE_V0.1.md in af-data-pipeline.
    TEXT

    InitResult = Struct.new(:path, :artifact, keyword_init: true)
    ValidationResult = Struct.new(:path, :artifact, :record_count, :sha256, keyword_init: true)

    module_function

    def init!(source_root:, source_id:, amc_path:, output_path:, registry_path: nil)
      root = expanded_source_root(source_root)
      amc = existing_file!(amc_path, "base AMC")
      output = File.expand_path(PrivateDataRoot.destination!(output_path))
      raise ValidationError, "Boundary freeze output already exists: #{output}" if File.exist?(output)

      registry = registry_context(root, registry_path)
      source_id = nonblank_string!(source_id, "source_id")
      entry = registry.fetch("sources")[source_id]
      raise ValidationError, "Source registry has no entry for #{source_id.inspect}" unless entry

      normalized_entry = normalize_registry_entry(source_id, entry)
      markdown_files = normalized_entry.fetch(:files).map do |filename|
        path = source_file!(root, filename)
        { "filename" => filename, "sha256" => sha256(path) }
      end

      artifact = {
        "schema_version" => SCHEMA_VERSION,
        "state" => "draft",
        "source" => {
          "canonical_source_id" => source_id,
          "registry_filename" => registry.fetch("relative_path"),
          "registry_sha256" => sha256(registry.fetch("path")),
          "markdown_files" => markdown_files
        },
        "base_amc" => {
          "filename" => File.basename(amc),
          "sha256" => sha256(amc)
        },
        "approval" => {
          "approved_by" => nil,
          "approved_at" => nil
        },
        "records" => []
      }

      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, HANDOFF_HEADER + YAML.dump(artifact))
      InitResult.new(path: output, artifact: artifact)
    end

    def validate!(freeze_path:, source_root:, amc_path:, registry_path: nil)
      freeze = existing_file!(freeze_path, "boundary freeze")
      root = expanded_source_root(source_root)
      amc = existing_file!(amc_path, "base AMC")
      artifact = load_yaml_mapping(freeze, "boundary freeze")

      exact_keys!(artifact, %w[schema_version state source base_amc approval records], "boundary freeze")
      require_keys!(artifact, %w[schema_version state source base_amc approval records], "boundary freeze")
      unless artifact["schema_version"] == SCHEMA_VERSION
        raise ValidationError,
              "Unsupported boundary freeze schema #{artifact['schema_version'].inspect}; expected #{SCHEMA_VERSION.inspect}"
      end
      raise ValidationError, 'Boundary freeze state must be "frozen"' unless artifact["state"] == "frozen"

      registry = registry_context(root, registry_path)
      normalized_entry = validate_source!(artifact.fetch("source"), registry, root)
      validate_base_amc!(artifact.fetch("base_amc"), amc)
      validate_approval!(artifact.fetch("approval"))
      records = validate_records!(artifact.fetch("records"), normalized_entry)

      ValidationResult.new(
        path: freeze,
        artifact: artifact,
        record_count: records.length,
        sha256: sha256(freeze)
      )
    end

    def validate_source!(source, registry, root)
      mapping!(source, "source")
      exact_keys!(source, %w[canonical_source_id registry_filename registry_sha256 markdown_files], "source")
      require_keys!(source, %w[canonical_source_id registry_filename registry_sha256 markdown_files], "source")

      source_id = nonblank_string!(source["canonical_source_id"], "source.canonical_source_id")
      registry_filename = nonblank_string!(source["registry_filename"], "source.registry_filename")
      unless registry_filename == registry.fetch("relative_path")
        raise ValidationError,
              "Source registry filename mismatch: freeze=#{registry_filename.inspect} actual=#{registry.fetch('relative_path').inspect}"
      end
      verify_sha!(source["registry_sha256"], registry.fetch("path"), "source registry")

      entry = registry.fetch("sources")[source_id]
      raise ValidationError, "Source registry has no entry for #{source_id.inspect}" unless entry
      normalized_entry = normalize_registry_entry(source_id, entry)

      markdown = source["markdown_files"]
      unless markdown.is_a?(Array) && !markdown.empty?
        raise ValidationError, "source.markdown_files must be a non-empty list"
      end
      filenames = markdown.map.with_index do |item, index|
        label = "source.markdown_files[#{index}]"
        mapping!(item, label)
        exact_keys!(item, %w[filename sha256], label)
        require_keys!(item, %w[filename sha256], label)
        filename = nonblank_string!(item["filename"], "#{label}.filename")
        path = source_file!(root, filename)
        verify_sha!(item["sha256"], path, "Markdown source #{filename.inspect}")
        filename
      end
      if filenames.uniq.length != filenames.length
        raise ValidationError, "source.markdown_files contains duplicate filenames"
      end
      expected = normalized_entry.fetch(:files)
      unless filenames == expected
        raise ValidationError,
              "Registered Markdown file set changed: freeze=#{filenames.inspect} registry=#{expected.inspect}"
      end
      normalized_entry
    end

    def validate_base_amc!(base_amc, amc)
      mapping!(base_amc, "base_amc")
      exact_keys!(base_amc, %w[filename sha256], "base_amc")
      require_keys!(base_amc, %w[filename sha256], "base_amc")
      filename = nonblank_string!(base_amc["filename"], "base_amc.filename")
      unless filename == File.basename(amc)
        raise ValidationError,
              "Base AMC filename mismatch: freeze=#{filename.inspect} actual=#{File.basename(amc).inspect}"
      end
      verify_sha!(base_amc["sha256"], amc, "base AMC")
    end

    def validate_approval!(approval)
      mapping!(approval, "approval")
      exact_keys!(approval, %w[approved_by approved_at], "approval")
      require_keys!(approval, %w[approved_by approved_at], "approval")
      nonblank_string!(approval["approved_by"], "approval.approved_by")
      value = nonblank_string!(approval["approved_at"], "approval.approved_at")
      return if valid_approval_time?(value)

      raise ValidationError, "approval.approved_at must be an ISO-8601 date or timestamp"
    end

    def validate_records!(records, normalized_entry)
      raise ValidationError, "records must be a list" unless records.is_a?(Array)

      allowed = %w[
        local_key canonical_title printed_pages pdf_pages parent_key parent_adventure_id
        levels editorial_rationale state
      ]
      required = %w[local_key canonical_title printed_pages editorial_rationale state]
      by_key = {}

      records.each_with_index do |record, index|
        label = "records[#{index}]"
        mapping!(record, label)
        exact_keys!(record, allowed, label)
        require_keys!(record, required, label)

        key = nonblank_string!(record["local_key"], "#{label}.local_key")
        raise ValidationError, "Duplicate record local_key #{key.inspect}" if by_key.key?(key)
        by_key[key] = record
        nonblank_string!(record["canonical_title"], "#{label}.canonical_title")
        nonblank_string!(record["editorial_rationale"], "#{label}.editorial_rationale")
        raise ValidationError, "#{label}.state must be \"frozen\"" unless record["state"] == "frozen"

        pages = page_span!(record["printed_pages"], "#{label}.printed_pages")
        page_span!(record["pdf_pages"], "#{label}.pdf_pages") if record.key?("pdf_pages") && !record["pdf_pages"].nil?
        levels!(record["levels"], "#{label}.levels") if record.key?("levels") && !record["levels"].nil?
        parent_reference!(record, label)
        validate_registry_range!(normalized_entry, pages, label)
      end

      records.each_with_index do |record, index|
        next unless present_string?(record["parent_key"])

        label = "records[#{index}]"
        parent = by_key[record["parent_key"]]
        raise ValidationError, "#{label}.parent_key references unknown local record #{record['parent_key'].inspect}" unless parent
        raise ValidationError, "#{label}.parent_key cannot reference itself" if parent.equal?(record)
      end
      validate_parent_cycles!(by_key)

      records
    end

    def parent_reference!(record, label)
      parent_key = present_string?(record["parent_key"]) ? record["parent_key"] : nil
      parent_id = present_string?(record["parent_adventure_id"]) ? record["parent_adventure_id"] : nil
      if record.key?("parent_key") && !record["parent_key"].nil? && !parent_key
        raise ValidationError, "#{label}.parent_key must be a nonblank string when present"
      end
      if record.key?("parent_adventure_id") && !record["parent_adventure_id"].nil? && !parent_id
        raise ValidationError, "#{label}.parent_adventure_id must be a nonblank string when present"
      end
      if parent_key && parent_id
        raise ValidationError, "#{label} cannot set both parent_key and parent_adventure_id"
      end
      if parent_id && !ADV_ID_RE.match?(parent_id)
        raise ValidationError, "#{label}.parent_adventure_id must match ADV-####"
      end
    end

    def validate_parent_cycles!(by_key)
      states = {}
      visit = lambda do |key|
        case states[key]
        when :visiting
          raise ValidationError, "parent_key cycle detected involving #{key.inspect}"
        when :done
          return
        end

        states[key] = :visiting
        parent_key = by_key.fetch(key)["parent_key"]
        visit.call(parent_key) if present_string?(parent_key)
        states[key] = :done
      end
      by_key.each_key { |key| visit.call(key) }
    end

    def page_span!(value, label)
      mapping!(value, label)
      exact_keys!(value, %w[start end], label)
      require_keys!(value, %w[start end], label)
      start_page = positive_integer!(value["start"], "#{label}.start")
      end_page = positive_integer!(value["end"], "#{label}.end")
      raise ValidationError, "#{label}.start exceeds end" if start_page > end_page
      { start: start_page, end: end_page }
    end

    def levels!(value, label)
      mapping!(value, label)
      exact_keys!(value, %w[start end], label)
      require_keys!(value, %w[start end], label)
      start_level = positive_integer!(value["start"], "#{label}.start")
      end_level = positive_integer!(value["end"], "#{label}.end")
      raise ValidationError, "#{label}.start exceeds end" if start_level > end_level
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def validate_registry_range!(entry, pages, label)
      source_markdown_call(:validate_registry_range!, entry, pages, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def registry_context(root, registry_path)
      source_markdown_call(:registry_context, root, registry_path)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def normalize_registry_entry(source_id, entry)
      source_markdown_call(:normalize_registry_entry, source_id, entry)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def validate_offset!(value, label)
      source_markdown_call(:validate_offset!, value, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def source_file!(root, filename)
      source_markdown_call(:source_file!, root, filename)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def relative_filename!(value, label)
      source_markdown_call(:relative_filename!, value, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def relative_under_root!(root, path, label)
      source_markdown_call(:relative_under_root!, root, path, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def expanded_source_root(path)
      source_markdown_call(:expanded_source_root, path)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def existing_file!(path, label)
      source_markdown_call(:existing_file!, path, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def load_yaml_mapping(path, label)
      source_markdown_call(:load_yaml_mapping, path, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def mapping!(value, label)
      source_markdown_call(:mapping!, value, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def exact_keys!(hash, allowed, label)
      source_markdown_call(:exact_keys!, hash, allowed, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def require_keys!(hash, required, label)
      source_markdown_call(:require_keys!, hash, required, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def nonblank_string!(value, label)
      source_markdown_call(:nonblank_string!, value, label)
    end

    def present_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def positive_integer!(value, label)
      source_markdown_call(:positive_integer!, value, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def verify_sha!(declared, path, label)
      source_markdown_call(:verify_sha!, declared, path, label)
    end

    # Forward these source/value inputs to MD; preserve ValidationError and return shape.
    def sha256(path)
      source_markdown_call(:sha256, path)
    end

    # Call the selected owner with positional source/value inputs; return its
    # result and translate only its validation error to the pipeline boundary.
    def source_markdown_call(method, *arguments)
      owner = SourceMarkdownOwner.load!(error_class: ValidationError)
      owner::Registry.public_send(method, *arguments)
    rescue StandardError => error
      raise ValidationError, error.message if defined?(AFSourceMD::ValidationError) && error.is_a?(AFSourceMD::ValidationError)
      raise
    end

    def valid_approval_time?(value)
      if /\A\d{4}-\d{2}-\d{2}\z/.match?(value)
        Date.iso8601(value)
      else
        Time.iso8601(value)
      end
      true
    rescue ArgumentError
      false
    end
  end
end
