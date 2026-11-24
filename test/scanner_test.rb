# frozen_string_literal: true
require_relative "test_helper"
class ScannerTest < Minitest::Test
  def test_scans_files_with_stable_hashes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir,"a.txt"),"hello"); FileUtils.mkdir_p(File.join(dir,"nested")); File.write(File.join(dir,"nested","b.json"),"{}")
      e=AfDataPipeline::Scanner.new(root:dir).scan; assert_equal ["a.txt","nested/b.json"],e.map(&:relative_path); assert_equal 64,e.first.sha256.length; assert_equal ".json",e.last.extension
    end
  end
  def test_reports_scan_progress
    Dir.mktmpdir do |dir|
      3.times { |i| File.write(File.join(dir,"#{i}.txt"),"hello #{i}") }
      events=[]
      AfDataPipeline::Scanner.new(root:dir).scan(progress: ->(event) { events << event }, progress_every: 2)
      assert_equal({phase: :scan, current: 0, total: 3}, events[0])
      assert_equal({phase: :scan, current: 2, total: 3}, events[1])
      assert_equal({phase: :scan, current: 3, total: 3}, events[2])
    end
  end

  def test_ignores_macos_packaging_artifacts_before_progress_counting
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir,"evidence"))
      File.write(File.join(dir,"evidence","result.json"),"{}")
      File.write(File.join(dir,"evidence","._result.json"),"appledouble")
      File.write(File.join(dir,"evidence",".DS_Store"),"finder")
      FileUtils.mkdir_p(File.join(dir,"__MACOSX","evidence"))
      File.write(File.join(dir,"__MACOSX","evidence","._result.json"),"resource fork")

      events=[]
      entries=AfDataPipeline::Scanner.new(root:dir).scan(progress: ->(event) { events << event })

      assert_equal ["evidence/result.json"], entries.map(&:relative_path)
      assert_equal({phase: :scan, current: 0, total: 1}, events.first)
      assert_equal({phase: :scan, current: 1, total: 1}, events.last)
    end
  end

end
