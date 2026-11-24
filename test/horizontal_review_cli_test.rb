# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/horizontal_package_fixture"
require "stringio"

class HorizontalReviewCliTest < Minitest::Test
  include HorizontalPackageFixture

  def test_horizontal_review_writes_auditable_packet
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source")
      output = File.join(dir, "review")
      FileUtils.mkdir_p(source)
      write_horizontal_package(
        source,
        specs: [
          interpretive_spec(adventure_id: "ADV-0200", dimension: "Seriousness", value: 2),
          interpretive_spec(adventure_id: "ADV-0251", dimension: "Seriousness", value: 3)
        ]
      )

      out = StringIO.new
      err = StringIO.new
      status = AfDataPipeline::CLI.run(
        [
          "horizontal-review", source,
          "--through", "ADV-0251",
          "--dimension", "Seriousness",
          "--expect-count", "2",
          "--output", output
        ],
        out:,
        err:
      )

      assert_equal 0, status, err.string
      assert File.file?(File.join(output, "inventory.jsonl"))
      assert File.file?(File.join(output, "results.jsonl"))
      assert File.file?(File.join(output, "audit_review.md"))
      assert File.file?(File.join(output, "integrity_report.json"))

      lines = File.readlines(File.join(output, "results.jsonl"))
      assert_equal 2, lines.length
      assert_equal "ADV-0251", JSON.parse(lines.last)["adventure_id"]

      report = JSON.parse(File.read(File.join(output, "integrity_report.json")))
      assert_equal 2, report["records_selected"]
      assert_equal 0, report["mechanically_invalid_records"]
      assert_empty report["errors"]

      review = File.read(File.join(output, "audit_review.md"))
      assert_includes review, "ADV-0251"
      assert_includes review, "Fixture raw reasoning 2."
      assert_empty err.string
    end
  end
end
