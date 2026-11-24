# frozen_string_literal: true

require_relative "private_data_root"

require_relative "error"

module AfDataPipeline
  # Compatibility read adapter; supported promotion workflow remains in PL.
  class ProjectState < AfXlsxFiles::ProjectState
    prepend XlsxFilesErrors.wrap(:validate!, :resolve, :promote!)

    # Promote exactly one shared moving role. The artifact must already exist
    # beside PROJECT_STATE.yml. Other roles are deliberately left untouched.
    def promote!(role:, artifact_path:, version:)
      PrivateDataRoot.external_store!(File.dirname(manifest_path))
      role = normalize_role(role)
      version = version.to_s
      raise Error, "invalid AMC version #{version.inspect}" unless VERSION_RE.match?(version)

      validate! unless @data
      current_version = @data.fetch(role).fetch("version")
      if compare_versions(version, current_version).negative?
        raise Error, "#{role} cannot move backward from #{current_version} to #{version}"
      end

      artifact = File.expand_path(artifact_path)
      root = manifest_root
      unless File.dirname(artifact) == root
        raise Error, "promoted artifact must live beside PROJECT_STATE.yml: #{artifact}"
      end

      expected_filename = canonical_filename(version)
      unless File.basename(artifact) == expected_filename
        raise Error, "artifact filename must be #{expected_filename.inspect} for version #{version}"
      end
      raise Error, "missing promoted artifact: #{artifact}" unless File.file?(artifact)

      candidate = deep_copy(@data)
      candidate[role] = {
        "version" => version,
        "filename" => File.basename(artifact),
        "sha256" => Digest::SHA256.file(artifact).hexdigest,
        "bytes" => File.size(artifact)
      }
      validate_data!(candidate)
      write_atomic!(candidate)
      @data = candidate
      resolve(role)
    end

    private

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def write_atomic!(data)
      temp_path = "#{manifest_path}.tmp-#{$$}"
      File.write(temp_path, YAML.dump(data))
      File.rename(temp_path, manifest_path)
    ensure
      FileUtils.rm_f(temp_path) if defined?(temp_path) && temp_path
    end
  end
end
