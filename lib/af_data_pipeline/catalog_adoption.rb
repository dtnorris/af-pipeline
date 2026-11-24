# frozen_string_literal: true

require_relative "private_data_root"

require "pathname"
require_relative "error"
require_relative "project_state"
require_relative "amc_adoption_review"
require_relative "amc_compatibility_check"
require_relative "standing_bulk_score_policy"
require_relative "final_release_package"
require_relative "catalog_replay_observation"

module AfDataPipeline
  # Pipeline admission for importing a reviewed AMC and advancing catalog_head.
  # The XLSX owner holds the lock while pipeline policy admits the transition.
  class CatalogAdoption
    unless defined?(AfXlsxFiles::Internal::CatalogStorage)
      raise LoadError, "the selected af-xlsx-files owner must support guarded catalog storage"
    end

    Storage = AfXlsxFiles::Internal::CatalogStorage
    private_constant :Storage
    prepend XlsxFilesErrors.wrap(:prepare!, :adopt!)

    PROOFS = {}
    private_constant :PROOFS
    Snapshot = Data.define(
      :manifest_path,
      :repository_root,
      :repository_head,
      :repository_remote,
      :prior_manifest,
      :roles,
      :candidate_path,
      :candidate,
      :version,
      :destination,
      :reuse_existing,
      :compatibility,
      :review,
      :scored_release
    ) do
      def initialize(scored_release: nil, **attributes)
        super(**attributes, scored_release:)
      end
    end
    Result = Data.define(:status, :resolved, :destination, :imported, :reused)

    def self.prepare!(manifest_path:, candidate_path:, version:, scored_release: nil)
      new(manifest_path:).prepare!(candidate_path:, version:, scored_release:)
    end

    # Adopt the reviewed snapshot or replay it. Optional pipeline callbacks
    # run under the lock; the completion block receives the outcome on success.
    # Refusals raise Error without publishing a new catalog head.
    def self.adopt!(snapshot:, before_mutation: nil, verify_review: nil, &complete)
      new(manifest_path: snapshot.manifest_path).adopt!(snapshot:, before_mutation:, verify_review:, &complete)
    end

    def initialize(manifest_path:)
      @manifest_path = File.expand_path(manifest_path)
    end

    def prepare!(candidate_path:, version:, scored_release: nil)
      candidate_path = File.expand_path(candidate_path)
      scored_release = bind_scored_release!(scored_release)
      version = version.to_s
      check!(ProjectState::VERSION_RE.match?(version), "invalid AMC version #{version.inspect}")
      validate_scored_package!(scored_release, candidate_path:, version:) if scored_release
      check!(File.file?(candidate_path), "missing AMC artifact: #{candidate_path}")
      check!(File.extname(candidate_path).casecmp(".xlsx").zero?, "AMC artifact must be an .xlsx file: #{candidate_path}")

      state, repository_root, repository_head, repository_remote = Storage.review!(@manifest_path)
      prior_manifest = state.binding
      roles = state.roles
      current = state.resolve("catalog_head")
      check!(compare_versions(version, current.version) >= 0,
             "catalog_head cannot move backward from #{current.version} to #{version}")
      destination = File.join(File.dirname(@manifest_path), canonical_filename(version))
      candidate = {"version" => version, "filename" => File.basename(destination),
                   **Storage.file_binding(candidate_path)}
      artifact_is_destination = candidate_path == File.expand_path(destination)
      reuse_existing = false
      if !artifact_is_destination && (File.exist?(destination) || File.symlink?(destination))
        check!(File.file?(destination) && Storage.file_binding(destination) == candidate.slice("sha256", "bytes"),
               "refusing to overwrite existing AMC artifact: #{destination}")
        reuse_existing = true
      end

      proof_key = [@manifest_path, candidate_path, version]
      proof_identity = [repository_root, repository_head, repository_remote, prior_manifest, roles, candidate,
                        destination, reuse_existing]
      proof = PROOFS[proof_key]
      if scored_release.nil? && proof && proof.fetch(:identity) == proof_identity
        compatibility = Marshal.load(proof.fetch(:compatibility))
        review = Marshal.load(proof.fetch(:review))
      else
        compatibility = AmcCompatibilityCheck.validate!(candidate_path:, base_path: current.path,
                                                        **scored_release_options(scored_release))
        review = AmcAdoptionReview.compare(current_path: current.path, candidate_path:)
        unless scored_release
          PROOFS.shift if PROOFS.length >= 16
          PROOFS[proof_key] = {identity: proof_identity, compatibility: Marshal.dump(compatibility).freeze,
                              review: Marshal.dump(review).freeze}.freeze
        end
      end
      Snapshot.new(
        manifest_path: @manifest_path,
        repository_root:,
        repository_head:,
        repository_remote:,
        prior_manifest:,
        roles:,
        candidate_path:,
        candidate:,
        version:,
        destination:,
        reuse_existing:,
        compatibility:,
        review:,
        scored_release:
      )
    end

    # Revalidate the reviewed inputs inside the owner's catalog lock. A fresh
    # transition runs admission before import and before manifest replacement.
    # Returns a Result or the completion block's value; refusals raise Error.
    def adopt!(snapshot:, before_mutation: nil, verify_review: nil)
      PrivateDataRoot.external_store!(File.dirname(@manifest_path))
      check!(File.expand_path(snapshot.manifest_path) == @manifest_path, "adoption snapshot belongs to another project state")
      Storage.with_lock(snapshot.repository_root) do |storage|
        resolved = storage.replay(snapshot)
        if resolved
          validate_scored_compatibility!(snapshot, base_path: snapshot.scored_release&.dig("base", "path"), replay: true)
          verify_review&.call(replay: true)
          result = Result.new(status: "ALREADY_PROMOTED", resolved:, destination: snapshot.destination,
                              imported: false, reused: true)
        else
          storage.assert_prior!(snapshot)
          fresh = prepare!(candidate_path: snapshot.candidate_path, version: snapshot.version,
                           scored_release: snapshot.scored_release)
          # The existing final-release wire request binds destination bytes and
          # locator. A matching file already at that locator can be reused.
          reviewed = snapshot.reuse_existing.nil? ? snapshot.with(reuse_existing: fresh.reuse_existing) : snapshot
          check!(fresh == reviewed, "catalog adoption inputs changed after review; prepare a fresh review")
          before_mutation&.call(fresh)
          verify_review&.call(replay: false)
          resolved, imported = storage.publish!(fresh) do
            before_promotion!(fresh)
            base = File.join(File.dirname(fresh.manifest_path), fresh.roles.dig("catalog_head", "filename"))
            validate_scored_compatibility!(fresh, base_path: base)
            verify_review&.call(replay: false)
          end
          result = Result.new(status: "PROMOTED", resolved:, destination: fresh.destination,
                              imported:, reused: fresh.reuse_existing)
        end
        block_given? ? yield(result) : result
      end
    end

    private

    def bind_scored_release!(references)
      return nil if references.nil?
      required = %w[release_manifest base staged package package_inputs]
      check!(references.is_a?(Hash) && (references.keys - [*required, "frontier"]).empty? &&
             (required - references.keys).empty?, "incomplete scored-release provenance")
      references.to_h do |name, reference|
        check!(reference.is_a?(Hash) && reference.keys.sort == %w[bytes path sha256] &&
               reference["path"].is_a?(String) && Pathname.new(reference["path"]).absolute?,
               "invalid scored-release #{name} reference")
        path = reference.fetch("path")
        check!(File.file?(path) && StandingBulkScorePolicy.file_binding(path) == reference.slice("sha256", "bytes"),
               "scored-release #{name} evidence is missing or changed")
        [name.dup.freeze, reference.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze]
      end.freeze
    end

    def scored_release_options(references)
      return {} unless references
      {release_manifest_path: references.fetch("release_manifest").fetch("path"),
       staged_path: references.fetch("staged").fetch("path"),
       release_base_path: references.fetch("base").fetch("path"),
       frontier_result_path: references.dig("frontier", "path")}
    end

    def validate_scored_compatibility!(snapshot, base_path:, replay: false)
      return unless snapshot.scored_release
      references = bind_scored_release!(snapshot.scored_release)
      observation = nil
      if replay
        package = JSON.parse(File.binread(references.fetch("package").fetch("path")))
        observation = CatalogReplayObservation.new(snapshot:,
          historical_binding: package.fetch("provenance").fetch("nodes").fetch("current_project_state"))
      end
      package = validate_scored_package!(references, candidate_path: snapshot.candidate_path,
        version: snapshot.version, replay_observation: observation)
      check!(snapshot.roles == package.dig("transition", "current_roles") &&
             snapshot.repository_head == package.dig("transition", "catalog_repository", "head") &&
             snapshot.repository_remote == package.dig("transition", "catalog_repository", "remote_url") &&
             snapshot.candidate == package.dig("transition", "proposed_catalog_head") &&
             snapshot.prior_manifest == package.dig("provenance", "nodes", "current_project_state").slice("sha256", "bytes"),
             "scored-release package differs from the reviewed catalog observation")
      if observation
        state = observation.project_state(@manifest_path)
        state.validate!
        base_path = state.resolve("catalog_head").path
      end
      AmcCompatibilityCheck.validate!(candidate_path: snapshot.candidate_path, base_path:,
                                     **scored_release_options(references), replay_observation: observation)
      observation&.assert_current!
    end

    def validate_scored_package!(references, candidate_path:, version:, replay_observation: nil)
      package = FinalReleasePackage.validate!(inputs_path: references.fetch("package_inputs").fetch("path"),
        package_path: references.fetch("package").fetch("path"), replay_observation:).package
      check!(package.dig("readiness", "ready") &&
             package.dig("candidate", "selected", "path") == candidate_path &&
             package.dig("transition", "proposed_catalog_head", "version") == version &&
             package.dig("provenance", "nodes", "current_project_state", "path") == @manifest_path,
             "scored-release package is not ready for this exact catalog adoption")
      expected = {"release_manifest" => "release_manifest", "base" => "authority:base", "staged" => "authority:staged"}
      expected["frontier"] = "frontier_result" if package.dig("provenance", "nodes", "frontier_result")
      check!(references.keys.sort == [*expected.keys, "package", "package_inputs"].sort &&
             expected.all? { |name, node| references.fetch(name) == package.dig("provenance", "nodes", node)&.slice("path", "sha256", "bytes") },
             "scored-release references differ from the validated package")
      package
    end

    # Test seam for failures after import and before the atomic role transition.
    # Production returns nil and does not mutate the snapshot.
    def before_promotion!(_snapshot)
    end

    def canonical_filename(version)
      "5e_Adventure_Master_Catalog_#{version}.xlsx"
    end

    def compare_versions(left, right)
      a = left.to_s.split(".").map!(&:to_i)
      b = right.to_s.split(".").map!(&:to_i)
      length = [a.length, b.length].max
      (a + [0] * (length - a.length)) <=> (b + [0] * (length - b.length))
    end

    def check!(condition, message)
      raise Error, message unless condition
    end
  end
end
