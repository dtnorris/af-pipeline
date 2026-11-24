# frozen_string_literal: true
module AfDataPipeline
  class ReviewPacketWriter
    def initialize(output_dir); @output_dir=File.expand_path(PrivateDataRoot.destination!(output_dir)); end
    def write!(entries:, normalization:, source:, source_type:)
      FileUtils.mkdir_p(@output_dir)
      write_jsonl("inventory.jsonl",entries.map(&:to_h)); write_jsonl("results.jsonl",normalization.records.map(&:to_h)); write_review(normalization.records); write_integrity(entries:,normalization:,source:,source_type:)
    end
    private
    def write_jsonl(name,rows); File.open(File.join(@output_dir,name),"w") { |f| rows.each { |r| f.puts(JSON.generate(r)) } }; end
    def write_review(records)
      File.open(File.join(@output_dir,"audit_review.md"),"w") do |f|
        f.puts "# AdventureFinder Production Review Packet\n\nGenerated mechanically by af-data-pipeline.\nNo score has been editorially accepted by this artifact.\n"
        records.each_with_index do |record,i|
          d=record.to_h
          f.puts "\n## #{i+1} — #{d['adventure_id']} — #{d['dimension']}\n\n**Proposed score:** #{d['score']}\n\n### Reason\n\n#{d['reason']}\n\n### Provenance\n\n- Adapter: `#{d['adapter']}`\n- Source path: `#{d['source_path']}`\n- Source SHA-256: `#{d['source_sha256']}`\n"
        end
      end
    end
    def write_integrity(entries:,normalization:,source:,source_type:)
      r={"schema_version"=>"af-data-integrity-report/v0.1","source"=>File.expand_path(source),"source_type"=>source_type,"files_scanned"=>entries.length,"recognized_files"=>normalization.recognized_files.length,"unrecognized_files"=>normalization.unrecognized_files.length,"normalized_records"=>normalization.records.length,"errors"=>normalization.errors,"recognized"=>normalization.recognized_files,"unrecognized"=>normalization.unrecognized_files}
      File.write(File.join(@output_dir,"integrity_report.json"),JSON.pretty_generate(r)+"\n")
    end
  end
end
