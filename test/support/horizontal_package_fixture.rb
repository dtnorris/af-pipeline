# frozen_string_literal: true

module HorizontalPackageFixture
  PROD_INGEST6_CUTOFF = "experiments/production-backlog-012/production-backlog-012-qwen-seriousness-adv0251-v1.yml"
  PROD_INGEST6_FIRST_EXCLUDED = "experiments/production-ee-b001/production-ee-b001-gptoss-ee-adv0009-v1.yml"

  def write_horizontal_package(root, specs:, cutoff_manifest: nil, first_excluded: "experiments/next.yml")
    manifests = specs.each_with_index.map do |spec, index|
      experiment = spec.fetch(:experiment, format("fixture-run-%03d", index + 1))
      manifest = spec[:manifest] || "experiments/fixture/#{experiment}.yml"
      write_manifest(root, manifest, experiment)
      write_result(root, experiment, spec, index + 1)
      manifest
    end

    cutoff_manifest ||= manifests.last
    scope = [
      "AdventureFinder test ingest handoff",
      "INCLUSIVE CUTOFF:",
      cutoff_manifest,
      "",
      "FIRST EXCLUDED:",
      first_excluded,
      "",
      "SCOPED RUN-ORDER ENTRIES: #{manifests.length}",
      "",
      *manifests,
      ""
    ].join("\n")
    File.write(File.join(root, "INGEST_SCOPE.txt"), scope)
  end

  def interpretive_spec(adventure_id:, dimension:, value: 3, raw_value: value, experiment: nil, manifest: nil)
    {
      adventure_id:,
      dimension:,
      value:,
      raw_value:,
      experiment:,
      manifest:,
      metric_kind: "interpretive"
    }.compact
  end

  def levels_spec(adventure_id:, start_value: 1, end_value: 4, experiment: "levels-fixture", manifest: nil)
    {
      adventure_id:,
      dimension: "Levels",
      experiment:,
      manifest:,
      rows: [
        { "metric_kind" => "level", "metric" => "Level Start", "value" => start_value, "rationale" => "Starts at level #{start_value}." },
        { "metric_kind" => "level", "metric" => "Level End", "value" => end_value, "rationale" => "Ends at level #{end_value}." }
      ],
      structured_content: {
        "group" => "sessions_levels",
        "level_start" => { "value" => start_value, "rationale" => "Starts at level #{start_value}." },
        "level_end" => { "value" => end_value, "rationale" => "Ends at level #{end_value}." }
      }
    }.compact
  end

  private

  def write_manifest(root, manifest, experiment)
    path = File.join(root, manifest)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "name: #{experiment}\n")
  end

  def write_result(root, experiment, spec, ordinal)
    base = File.join(root, "output", experiment, "runs", "run-001", "native")
    assessments = File.join(base, "assessments")
    raw = File.join(base, "raw")
    FileUtils.mkdir_p(assessments)
    FileUtils.mkdir_p(raw)

    rows = spec[:rows] || [
      {
        "metric_kind" => spec.fetch(:metric_kind),
        "metric" => spec.fetch(:dimension),
        "value" => spec.fetch(:value),
        "rationale" => "Fixture rationale #{ordinal}.",
        "adjacent_lower_reason" => "Lower does not fit.",
        "adjacent_higher_reason" => "Higher does not fit."
      }
    ]

    headers = %w[
      run_id status adventure_id adventure_title provider model group metric_kind metric value
      rationale adjacent_lower_reason adjacent_higher_reason
    ]
    CSV.open(File.join(assessments, "assessment.csv"), "w") do |csv|
      csv << headers
      rows.each do |row|
        full = {
          "run_id" => "fixture-#{ordinal}",
          "status" => "PROPOSED",
          "adventure_id" => spec.fetch(:adventure_id),
          "adventure_title" => "Fixture Adventure #{ordinal}",
          "provider" => "ollama",
          "model" => "fixture-model",
          "group" => "fixture"
        }.merge(row.transform_keys(&:to_s))
        csv << headers.map { |header| full[header] }
      end
    end

    structured = spec[:structured_content] || {
      "group" => "fixture",
      "dimensions" => [
        {
          "dimension" => spec.fetch(:dimension),
          "score" => spec.fetch(:raw_value),
          "rationale" => "Fixture rationale #{ordinal}."
        }
      ]
    }
    payload = {
      "model" => "fixture-model",
      "choices" => [
        {
          "finish_reason" => "stop",
          "message" => {
            "content" => JSON.generate(structured),
            "reasoning" => "Fixture raw reasoning #{ordinal}."
          }
        }
      ],
      "usage" => { "total_tokens" => 100 }
    }
    File.write(File.join(raw, "dimension_fixture.json"), JSON.generate(payload))
  end
end
