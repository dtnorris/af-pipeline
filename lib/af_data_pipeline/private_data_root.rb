# frozen_string_literal: true

require "pathname"
require_relative "error"

module AfDataPipeline
  # Destination boundary for public pipeline commands and their private stores.
  module PrivateDataRoot
    ENV_KEY = "AF_DATA_PIPELINE_DATA_ROOT"
    CODE_ROOT = File.realpath(File.expand_path("../..", __dir__))

    # Returns the selected existing private directory, or nil for legacy mode.
    # Raises ValidationError for an empty, unsafe, overlapping or unwritable root.
    def self.selected
      return nil unless ENV.key?(ENV_KEY)

      root = clean_path!(ENV.fetch(ENV_KEY))
      unless Pathname.new(root).absolute? && File.directory?(root)
        raise ValidationError, "#{ENV_KEY} must name an existing absolute directory"
      end
      root = File.expand_path(root)
      reject_symlinks!(root)
      if within?(root, CODE_ROOT) || within?(CODE_ROOT, root)
        raise ValidationError, "private data root overlaps executable code"
      end
      writable!(root)
      root
    end

    # Return the selected data directory or raise ValidationError before a write.
    def self.require_selected!
      selected || raise(ValidationError, "set #{ENV_KEY} to an existing absolute private data directory")
    end

    # Run a durable CLI with a validated root. Report directory errors with exit status 2.
    def self.run_cli
      require_selected!
      yield
    rescue ValidationError => error
      warn "ERROR: #{error.message}"
      2
    end

    # Validate a separately selected source or catalog store before a write.
    # The owning component still validates the exact paths within its store.
    def self.external_store!(path)
      return unless selected

      root = File.realpath(clean_path!(path))
      unless File.directory?(root) && !within?(root, CODE_ROOT) && !within?(CODE_ROOT, root)
        raise ValidationError, "private source or catalog store overlaps executable code or is not a directory"
      end
      writable!(root)
      root
    rescue SystemCallError => error
      raise ValidationError, "invalid private source or catalog store: #{error.message}"
    end

    # Resolves an existing pipeline-root selector against the opt-in root.
    # An explicit disagreement raises ValidationError; absence keeps old defaults.
    def self.resolve(legacy_root = nil, default: CODE_ROOT)
      root = selected
      if root && legacy_root && File.expand_path(clean_path!(legacy_root)) != root
        raise ValidationError, "pipeline root conflicts with #{ENV_KEY}"
      end
      root || File.expand_path(legacy_root || default)
    end

    # Returns a legacy default unchanged, or its location under the private root.
    # Raises ValidationError when the selected root or derived output is unsafe.
    def self.default_path(relative)
      root = selected
      root ? destination!(File.join(root, relative)) : relative
    end

    # Validates an AFDP output/replay destination before any publication. Returns
    # the original path in legacy mode, otherwise an absolute contained path.
    # Rejects traversal, symlinks (including existing descendants), special files
    # and unwritable parents with ValidationError. No directories are created.
    def self.destination!(path)
      root = selected
      return path unless root

      expanded = File.expand_path(clean_path!(path))
      raise ValidationError, "AFDP destination escapes private data root: #{expanded}" unless within?(expanded, root)

      reject_symlinks!(expanded)
      if File.directory?(expanded)
        Dir.glob(File.join(expanded, "**", "*"), File::FNM_DOTMATCH).each do |entry|
          reject_entry!(entry)
        end
      elsif File.exist?(expanded)
        reject_entry!(expanded)
      end
      parent = expanded
      parent = File.dirname(parent) until File.exist?(parent)
      writable!(parent)
      expanded
    end

    # Validates spelling before normalization can hide explicit traversal. Returns
    # the supplied string; raises ValidationError for blank/NUL/dot-segment paths.
    def self.clean_path!(path)
      value = path.to_s
      if value.strip.empty? || value.include?("\0") || value.split(File::SEPARATOR).any? { |part| %w[. ..].include?(part) }
        raise ValidationError, "private data path is empty or contains traversal"
      end
      value
    end

    # Returns whether path is root or strictly beneath it; no filesystem writes.
    def self.within?(path, root)
      path == root || path.start_with?(root + File::SEPARATOR)
    end

    # Rejects symlinks in every existing ancestor, including dangling links.
    # Raises ValidationError; returns nil after a safe ancestor walk.
    def self.reject_symlinks!(path)
      current = File.expand_path(path)
      loop do
        raise ValidationError, "private data path contains a symlink: #{current}" if File.symlink?(current)
        break if current == File.dirname(current)

        current = File.dirname(current)
      end
      nil
    end

    # Rejects links and special files in an existing destination inventory.
    # Raises ValidationError; returns nil for regular files and directories.
    def self.reject_entry!(path)
      unless !File.symlink?(path) && (File.file?(path) || File.directory?(path))
        raise ValidationError, "unsafe private data entry: #{path}"
      end
      nil
    end

    # Requires OS write access and an explicit write permission bit. Returns nil
    # or raises ValidationError, including when running as a privileged test user.
    def self.writable!(path)
      unless File.writable?(path) && (File.stat(path).mode & 0o222).positive?
        raise ValidationError, "private data destination is unwritable: #{path}"
      end
      nil
    end
  end
end
