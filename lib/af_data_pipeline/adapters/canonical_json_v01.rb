# frozen_string_literal: true
module AfDataPipeline
  module Adapters
    class CanonicalJsonV01 < Base
      def recognize?(entry)
        return false unless entry.extension==".json"
        parsed=parse(entry); parsed.is_a?(Hash) && parsed["schema_version"]==ResultRecord::SCHEMA_VERSION
      rescue JSON::ParserError
        false
      end
      def extract(entry)
        parsed=parse(entry)
        [ResultRecord.new(parsed.merge("source_path"=>entry.relative_path,"source_sha256"=>entry.sha256,"adapter"=>name))]
      end
      private
      def parse(entry); JSON.parse(File.read(entry.absolute_path, encoding:"UTF-8")); end
    end
  end
end
