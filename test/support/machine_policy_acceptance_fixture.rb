# frozen_string_literal: true

class MachinePolicyAcceptanceFixture
  attr_reader :record, :path, :roots, :bytes

  def initialize(root:, dimension: "Number of Sessions", metric: nil, state: "PROPOSED",
                 result: nil, conditions: nil, recorded_at: "2026-10-07T01:00:00Z")
    @root = root
    @roots = %w[pipeline afw wlo project].to_h do |name|
      path = File.join(root, name)
      FileUtils.mkdir_p(path)
      [name, path]
    end
    metric ||= dimension == "Levels" ? "Level Start" : dimension
    result ||= state == "ACCEPTED" ? "MACHINE_ACCEPTED" : "WOULD_MACHINE_ACCEPT"
    conditions ||= {
      "assessment_state" => "resolved",
      "review_flags" => [],
      "source_hold" => false,
      "existing_human_decision" => nil
    }
    @record = build_record(dimension:, metric:, state:, result:, conditions:, recorded_at:)
    seal!
    @path = File.join(root, "record-#{metric.downcase.tr(' ', '-')}.json")
    @bytes = JSON.pretty_generate(@record) + "\n"
    File.binwrite(@path, @bytes)
  end

  def current_bindings
    deep_copy(@record.slice(*AfDataPipeline::MachinePolicyAcceptance::BINDING_SECTIONS))
  end

  def rewrite!
    seal!
    @bytes = JSON.pretty_generate(@record) + "\n"
    File.binwrite(@path, @bytes)
  end

  def self.deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  private

  def build_record(dimension:, metric:, state:, result:, conditions:, recorded_at:)
    metric_slug = metric.downcase.tr(" ", "-")
    receipt_body = JSON.generate({ "fixture" => "receipt", "case_id" => "case-1" }) + "\n"
    receipt_reference = write_artifact("afw", "evidence/receipt.json", receipt_body)
    candidate = {
      "key" => "ADV-0001::#{metric}",
      "adventure_id" => "ADV-0001",
      "dimension" => dimension,
      "metric" => metric,
      "proposed_value" => dimension == "Levels" ? 3 : 8
    }
    candidate["content_sha256"] = digest(canonical_json(candidate))
    reasons = result == "HUMAN_REVIEW_REQUIRED" ? ["EXISTING_HUMAN_DECISION_PRESERVED"] : []
    record = {
      "schema_version" => AfDataPipeline::MachinePolicyAcceptance::SCHEMA_VERSION,
      "record_type" => AfDataPipeline::MachinePolicyAcceptance::RECORD_TYPE,
      "record_state" => state,
      "authority" => {
        "kind" => state == "ACCEPTED" ? "MACHINE_POLICY_ACCEPTANCE" : "MACHINE_POLICY_PROPOSAL",
        "authoritative" => state == "ACCEPTED",
        "human_reviewed" => false,
        "human_decision" => nil
      },
      "candidate" => candidate,
      "evidence" => {
        "receipt" => {
          "contract_version" => AfDataPipeline::MachinePolicyAcceptance::RECEIPT_CONTRACT,
          "semantic_status" => AfDataPipeline::MachinePolicyAcceptance::RECEIPT_STATUS,
          "receipt_id" => digest(canonical_json("case_id" => "case-1", "fixture" => "receipt")),
          "content_sha256" => receipt_reference.fetch("sha256"),
          "reference" => receipt_reference
        },
        "review_package" => write_artifact("pipeline", "review/package.json", "{\"fixture\":\"review\"}\n"),
        "scoring_artifacts" => [
          {
            "kind" => "proposed_assessment",
            "reference" => write_artifact(
              "afw", "evidence/#{metric_slug}-assessment.csv", "metric,value\n#{metric},3\n"
            )
          },
          {
            "kind" => "raw_response",
            "reference" => write_artifact("afw", "evidence/response.json", "{\"fixture\":\"response\"}\n")
          }
        ],
        "review_conditions" => deep_copy(conditions),
        "review_conditions_sha256" => digest(canonical_json(conditions))
      },
      "workload" => {
        "manifest_id" => "1" * 64,
        "manifest_sha256" => "2" * 64,
        "plan_id" => "plan-1",
        "plan_sha256" => "3" * 64,
        "case_id" => "case-1",
        "case" => write_artifact("afw", "workloads/plan-1/case.yml", "case_id: case-1\n"),
        "job_id" => "case-1",
        "plan_job_sha256" => "4" * 64
      },
      "attempt" => {
        "job_id" => "case-1",
        "number" => 1,
        "status" => "complete",
        "exit_status" => 0,
        "authoritative" => true,
        "retry" => false,
        "superseded" => false,
        "favorable_rerun" => false,
        "metadata" => write_artifact("wlo", "runs/case-1/metadata.json", "{\"status\":\"complete\"}\n")
      },
      "qualification" => {
        "state" => "LOCAL_QUALIFIED",
        "profile_id" => "synthetic-profile-v1",
        "artifact" => write_artifact("afw", "qualification/result.json", "{\"state\":\"LOCAL_QUALIFIED\"}\n"),
        "profile" => write_artifact("afw", "qualification/profile.yml", "profile: synthetic-profile-v1\n"),
        "afw_contract_sha256" => "5" * 64,
        "model" => { "alias" => "synthetic", "manifest_digest" => "6" * 64 },
        "runtime" => { "identity" => "synthetic-runtime", "sha256" => "7" * 64 }
      },
      "policy" => {
        "schema_version" => AfDataPipeline::MachinePolicyAcceptance::POLICY_SCHEMA,
        "id" => "qualification-aware-scoring-acceptance",
        "version" => "0.1",
        "status" => state == "ACCEPTED" ? "ENABLED" : "CANDIDATE_NOT_ENABLED",
        "artifact" => write_artifact("pipeline", "config/policy.yml", "id: qualification-aware-scoring-acceptance\n")
      },
      "decision" => {
        "result" => result,
        "reasons" => reasons,
        "evaluation_input" => write_artifact("pipeline", "evaluations/input.json", "{\"fixture\":\"input\"}\n"),
        "evaluation_output" => write_artifact("pipeline", "evaluations/output.json", "{\"fixture\":\"output\"}\n")
      },
      "prerequisites" => prerequisites(state),
      "evaluator" => software_identity("policy-evaluator", "8"),
      "producer" => software_identity("af-data-pipeline", "9"),
      "recorded_at" => recorded_at
    }
    record
  end

  def prerequisites(state)
    if state == "ACCEPTED"
      {
        "ig12b_evaluation" => {
          "status" => "PASSED",
          "artifact" => write_artifact("project", "authority/ig-12b.json", "{\"result\":\"passed\"}\n")
        },
        "application_authorization" => {
          "status" => "GRANTED",
          "artifact" => write_artifact("project", "authority/application.json", "{\"status\":\"granted\"}\n")
        }
      }
    else
      {
        "ig12b_evaluation" => { "status" => "NOT_EVALUATED", "artifact" => nil },
        "application_authorization" => { "status" => "NOT_GRANTED", "artifact" => nil }
      }
    end
  end

  def software_identity(id, digit)
    { "id" => id, "version" => "0.1", "git_commit" => digit * 40, "code_sha256" => digit * 64 }
  end

  def write_artifact(root_name, relative, bytes)
    path = File.join(@roots.fetch(root_name), relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    { "root" => root_name, "path" => relative, "sha256" => digest(bytes) }
  end

  def seal!
    bindings = @record.slice(*AfDataPipeline::MachinePolicyAcceptance::BINDING_SECTIONS)
    @record["binding_sha256"] = digest(canonical_json(bindings))
    identity = @record.reject { |key, _value| %w[record_id recorded_at].include?(key) }
    @record["record_id"] = digest(canonical_json(identity))
  end

  def canonical_json(value)
    JSON.generate(canonical(value))
  end

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end

  def digest(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def deep_copy(value)
    self.class.deep_copy(value)
  end
end
