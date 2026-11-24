# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "error"

module AfDataPipeline
  # The two public definitions used by new boundary editorial bundles. This
  # content binding identifies the reviewed source revision, not an installation
  # or semantic approval. Historical bundles do not use this selection.
  module EditorialSpecifications
    REPOSITORY = "https://github.com/dtnorris/af-specification-md"
    REVISION = "394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf"
    INVENTORY_SHA256 = "5ebb0fffcafa165a71bd3afef70e483217074d788d02ff9241ab3cedfd6bf0e6"
    DOCUMENTS = [
      { "filename" => "Adventure_Catalog_Editorial_Specification_Rev_2.0.md",
        "version" => "2.0", "status" => "Draft",
        "sha256" => "f07aafb6240be0a4fd43f03bf8e6cdf3450a1980f05073511661df5d4b7197ce" }.freeze,
      { "filename" => "Adventure_Boundary_Detection_Specification_ABDS_v1.4.md",
        "version" => "1.4", "status" => "Accepted; selected for new work",
        "sha256" => "99bfa95019765213c4a138b66cd5bfa408754ba1d40732a4abefcaf71b262630" }.freeze
    ].freeze

    # Bind an explicit absolute document directory to the reviewed inventory
    # and exact required files. Returns a JSON-compatible identity; raises
    # ValidationError for missing, changed or symlinked inputs. No fallback.
    def self.bind!(root)
      unless root.is_a?(String) && Pathname.new(root).absolute? && File.directory?(root) &&
             File.realpath(root) == File.expand_path(root)
        raise ValidationError, "--spec-root must name an explicit absolute public specification directory"
      end
      root = File.realpath(root)
      verify_file!(File.join(root, "documents.json"), INVENTORY_SHA256)
      files = DOCUMENTS.map do |document|
        path = File.join(root, document.fetch("filename"))
        verify_file!(path, document.fetch("sha256"))
        document.merge("path" => path, "bytes" => File.size(path))
      end
      { "repository" => REPOSITORY, "revision" => REVISION,
        "inventory_sha256" => INVENTORY_SHA256, "root" => root, "files" => files }
    end

    # Recheck the frozen selection without accepting altered metadata or bytes.
    # Returns nil; raises ValidationError for any mismatch or unavailable input.
    def self.validate!(binding)
      unless binding.is_a?(Hash) && binding == bind!(binding["root"])
        raise ValidationError, "editorial public specification binding changed"
      end
      nil
    end

    # Check one exact file against its selected digest. Returns nil or raises
    # ValidationError; filesystem read errors are reported as unavailable input.
    def self.verify_file!(path, expected)
      unless File.file?(path) && !File.symlink?(path) && Digest::SHA256.file(path).hexdigest == expected
        raise ValidationError, "missing or changed public specification input: #{path}"
      end
      nil
    rescue SystemCallError => error
      raise ValidationError, "unavailable public specification input: #{path}: #{error.class}"
    end

    # Render a verified binding as attachment instructions for an operator.
    # Returns lines with exact identities; invalid/missing inputs raise ValidationError.
    def self.lines(binding)
      validate!(binding)
      ["Public editorial definitions: #{REPOSITORY}@#{REVISION}",
       "Inventory SHA-256: #{INVENTORY_SHA256}"] + binding.fetch("files").map do |document|
        "Attach #{document.fetch('path')} (#{document.fetch('version')}; #{document.fetch('status')}; " \
          "SHA-256 #{document.fetch('sha256')}; #{document.fetch('bytes')} bytes)"
      end
    end
  end
end
