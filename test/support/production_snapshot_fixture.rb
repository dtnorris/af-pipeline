# frozen_string_literal: true

module ProductionSnapshotFixture
  HEADERS = %w[
    run_id status review_disposition adventure_id adventure_title source_book book_publisher
    start_page end_page afao_version assessment_spec_version provider model source_file source_scope
    group metric_kind metric assessment_state value range_low range_high confidence path_sensitive
    path_variation_affects_anchor rationale adjacent_lower_reason adjacent_higher_reason evidence
    metric_review_flags package_review_flags
  ].freeze

  def write_production_run(root, experiment:, adventure_id:, dimensions:, metadata_schema: :legacy,
                           raw_format: :openai, lme_run_id: nil, values: {}, success: true,
                           model: "fixture-model", provider: "ollama", repo_commit: "repo-sha",
                           scorer_commit: "scorer-sha")
    lme_run_id ||= "lme-#{experiment}"
    run_root = File.join(root, experiment, "runs", lme_run_id)
    native = File.join(run_root, "native")
    assessments = File.join(native, "assessments")
    FileUtils.mkdir_p(assessments)

    metadata = if metadata_schema == :legacy
                 {
                   "job_id" => lme_run_id,
                   "worker" => "mac",
                   "ollama_model" => model,
                   "adventure" => adventure_id,
                   "replicate" => 1,
                   "dimension" => dimensions.fetch(0),
                   "status" => success ? "complete" : "failed",
                   "started_at" => "2026-08-31T10:00:00-04:00",
                   "completed_at" => "2026-08-31T10:01:00-04:00",
                   "exit_status" => success ? 0 : 1
                 }
               else
                 {
                   "run_id" => lme_run_id,
                   "experiment_name" => experiment,
                   "repo_commit" => repo_commit,
                   "scorer_commit" => scorer_commit,
                   "started_at" => "2026-08-31T10:00:00-04:00",
                   "ended_at" => "2026-08-31T10:01:00-04:00",
                   "success" => success,
                   "model" => { "ollama_model" => model, "scorer_model" => model },
                   "job" => {
                     "adventure_id" => adventure_id,
                     "dimensions" => dimensions,
                     "replicate" => 1
                   }
                 }
               end
    File.write(File.join(run_root, "metadata.json"), JSON.pretty_generate(metadata))

    scoring_run_id = "20260831T140000Z_fixture"
    rows = dimensions.flat_map do |dimension|
      rows_for_dimension(adventure_id, dimension, values.fetch(dimension, nil), scoring_run_id, model, provider)
    end
    CSV.open(File.join(assessments, "assessment.csv"), "w") do |csv|
      csv << HEADERS
      rows.each { |row| csv << HEADERS.map { |header| row[header] } }
    end

    raw_root = File.join(native, "raw", adventure_id, scoring_run_id)
    FileUtils.mkdir_p(raw_root)
    dimensions.each do |dimension|
      structured = structured_for_dimension(dimension, values.fetch(dimension, nil))
      payload = if raw_format == :afcsu
                  {
                    "provider" => provider,
                    "model" => model,
                    "assistant" => {
                      "structured" => structured,
                      "raw_text" => JSON.generate(structured)
                    }
                  }
                else
                  {
                    "model" => model,
                    "choices" => [
                      {
                        "message" => {
                          "content" => JSON.generate(structured),
                          "reasoning" => "Fixture model reasoning for #{dimension}."
                        }
                      }
                    ]
                  }
                end
      slug = dimension.downcase.gsub(/[^a-z0-9]+/, "_").sub(/_+\z/, "")
      File.write(File.join(raw_root, "dimension_#{slug}.json"), JSON.pretty_generate(payload))
      File.write(File.join(raw_root, "dimension_#{slug}_request.json"), JSON.generate("request" => true))
    end
    File.write(File.join(raw_root, "run_metadata.json"), JSON.generate("fixture" => true))
    run_root
  end


  def mark_level_unresolved(run_root, metric:, rationale: "Source does not establish this level.")
    state = "Uncertain / Requires Source Verification"
    assessment_path = Dir.glob(File.join(run_root, "native", "assessments", "*.csv")).fetch(0)
    table = CSV.read(assessment_path, headers: true)
    row = table.find { |item| item["metric"] == metric }
    raise "fixture metric not found: #{metric}" unless row

    row["assessment_state"] = state
    row["value"] = nil
    row["review_disposition"] = "REVIEW_REQUIRED"
    row["metric_review_flags"] = "REVIEW:LEVEL_UNCERTAIN|REVIEW:EVIDENCE_INSUFFICIENT"
    row["rationale"] = rationale
    CSV.open(assessment_path, "w") do |csv|
      csv << table.headers
      table.each { |item| csv << table.headers.map { |header| item[header] } }
    end

    raw_path = Dir.glob(File.join(run_root, "native", "raw", "**", "dimension_levels.json")).fetch(0)
    payload = JSON.parse(File.read(raw_path))
    structured = payload.dig("assistant", "structured")
    if structured
      raw_metric = structured.fetch(metric == "Level Start" ? "level_start" : "level_end")
      raw_metric["assessment_state"] = state
      raw_metric["value"] = nil
      raw_metric["rationale"] = rationale
      payload.fetch("assistant")["raw_text"] = JSON.generate(structured)
    else
      message = payload.fetch("choices").fetch(0).fetch("message")
      structured = JSON.parse(message.fetch("content"))
      raw_metric = structured.fetch(metric == "Level Start" ? "level_start" : "level_end")
      raw_metric["assessment_state"] = state
      raw_metric["value"] = nil
      raw_metric["rationale"] = rationale
      message["content"] = JSON.generate(structured)
    end
    File.write(raw_path, JSON.pretty_generate(payload))
  end

  def mark_interpretive_insufficient_evidence(run_root, metric:, rationale: "Evidence is insufficient to score this dimension.")
    state = "Insufficient Evidence"
    assessment_path = Dir.glob(File.join(run_root, "native", "assessments", "*.csv")).fetch(0)
    table = CSV.read(assessment_path, headers: true)
    row = table.find { |item| item["metric"] == metric }
    raise "fixture metric not found: #{metric}" unless row

    row["assessment_state"] = state
    row["value"] = nil
    row["review_disposition"] = "REVIEW_REQUIRED"
    row["metric_review_flags"] = "REVIEW:INSUFFICIENT_EVIDENCE|REVIEW:EVIDENCE_INSUFFICIENT"
    row["rationale"] = rationale

    CSV.open(assessment_path, "w") do |csv|
      csv << table.headers
      table.each { |item| csv << table.headers.map { |header| item[header] } }
    end

    slug = metric.downcase.gsub(/[^a-z0-9]+/, "_").sub(/_+\z/, "")
    raw_path = Dir.glob(File.join(run_root, "native", "raw", "**", "dimension_#{slug}.json")).fetch(0)
    payload = JSON.parse(File.read(raw_path))
    structured = payload.dig("assistant", "structured")

    if structured
      raw_metric = Array(structured["dimensions"]).find { |item| item["dimension"] == metric }
      raise "fixture raw metric not found: #{metric}" unless raw_metric

      raw_metric["assessment_state"] = state
      raw_metric["score"] = nil
      raw_metric["rationale"] = rationale
      payload.fetch("assistant")["raw_text"] = JSON.generate(structured)
    else
      message = payload.fetch("choices").fetch(0).fetch("message")
      structured = JSON.parse(message.fetch("content"))
      raw_metric = Array(structured["dimensions"]).find { |item| item["dimension"] == metric }
      raise "fixture raw metric not found: #{metric}" unless raw_metric

      raw_metric["assessment_state"] = state
      raw_metric["score"] = nil
      raw_metric["rationale"] = rationale
      message["content"] = JSON.generate(structured)
    end

    File.write(raw_path, JSON.pretty_generate(payload))
  end

  def zip_directory(source, zip_path)
    Zip::File.open(zip_path, create: true) do |zip|
      Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
        next unless File.file?(path)

        relative = Pathname.new(path).relative_path_from(Pathname.new(source)).to_s
        zip.get_output_stream(relative) { |io| io.write(File.binread(path)) }
      end
    end
  end

  private

  def rows_for_dimension(adventure_id, dimension, supplied, run_id, model, provider)
    case dimension
    when "Levels"
      values = supplied || { start: 3, end: 5 }
      [
        base_row(adventure_id, run_id, model, provider).merge(
          "group" => "sessions_levels", "metric_kind" => "level", "metric" => "Level Start",
          "value" => values.fetch(:start), "rationale" => "Starts at level #{values.fetch(:start)}.",
          "evidence" => evidence("Level Start")
        ),
        base_row(adventure_id, run_id, model, provider).merge(
          "group" => "sessions_levels", "metric_kind" => "level", "metric" => "Level End",
          "value" => values.fetch(:end), "rationale" => "Ends at level #{values.fetch(:end)}.",
          "evidence" => evidence("Level End")
        )
      ]
    when "# of Sessions"
      values = supplied || { value: 4, low: 3, high: 5 }
      [base_row(adventure_id, run_id, model, provider).merge(
        "group" => "sessions_levels", "metric_kind" => "sessions", "metric" => "# of Sessions",
        "value" => values.fetch(:value), "range_low" => values.fetch(:low), "range_high" => values.fetch(:high),
        "rationale" => "Expected substantive play is four sessions.", "evidence" => evidence("# of Sessions")
      )]
    else
      value = supplied || 3
      [base_row(adventure_id, run_id, model, provider).merge(
        "group" => "fixture", "metric_kind" => "interpretive", "metric" => dimension,
        "value" => value, "confidence" => 85, "path_sensitive" => "false",
        "path_variation_affects_anchor" => "false", "rationale" => "Rationale for #{dimension} at #{value}.",
        "adjacent_lower_reason" => "Lower does not fit.", "adjacent_higher_reason" => "Higher does not fit.",
        "evidence" => evidence(dimension)
      )]
    end
  end

  def base_row(adventure_id, run_id, model, provider)
    {
      "run_id" => run_id,
      "status" => "PROPOSED",
      "review_disposition" => "NO_AUTOMATIC_REVIEW_TRIGGER",
      "adventure_id" => adventure_id,
      "adventure_title" => "Fixture Adventure",
      "source_book" => "Fixture Book",
      "book_publisher" => "Fixture Publisher",
      "start_page" => 1,
      "end_page" => 10,
      "afao_version" => "1.5.1",
      "assessment_spec_version" => "0.1",
      "provider" => provider,
      "model" => model,
      "source_file" => "/fixture/source.md",
      "source_scope" => "canonical_page_slice",
      "assessment_state" => "Scored",
      "metric_review_flags" => "",
      "package_review_flags" => ""
    }
  end

  def structured_for_dimension(dimension, supplied)
    case dimension
    when "Levels"
      values = supplied || { start: 3, end: 5 }
      {
        "group" => "sessions_levels",
        "level_start" => {
          "assessment_state" => "Scored", "value" => values.fetch(:start),
          "rationale" => "Starts at level #{values.fetch(:start)}.", "evidence" => JSON.parse(evidence("Level Start"))
        },
        "level_end" => {
          "assessment_state" => "Scored", "value" => values.fetch(:end),
          "rationale" => "Ends at level #{values.fetch(:end)}.", "evidence" => JSON.parse(evidence("Level End"))
        }
      }
    when "# of Sessions"
      values = supplied || { value: 4, low: 3, high: 5 }
      {
        "group" => "sessions_levels",
        "sessions" => {
          "assessment_state" => "Scored", "normalized_sessions" => values.fetch(:value),
          "practical_range_low" => values.fetch(:low), "practical_range_high" => values.fetch(:high),
          "rationale" => "Expected substantive play is four sessions.", "evidence" => JSON.parse(evidence("# of Sessions"))
        }
      }
    else
      value = supplied || 3
      {
        "group" => "fixture",
        "dimensions" => [
          {
            "dimension" => dimension, "assessment_state" => "Scored", "score" => value,
            "confidence" => 85, "path_sensitive" => false, "path_variation_affects_anchor" => false,
            "rationale" => "Rationale for #{dimension} at #{value}.",
            "adjacent_lower_reason" => "Lower does not fit.", "adjacent_higher_reason" => "Higher does not fit.",
            "evidence" => JSON.parse(evidence(dimension))
          }
        ]
      }
    end
  end

  def evidence(label)
    JSON.generate([{ "locator" => "Fixture p. 1", "note" => "Evidence for #{label}." }])
  end
end
