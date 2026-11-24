# frozen_string_literal: true
module AfDataPipeline
  module Adapters
    class Base
      def name; self.class.name.split("::").last; end
      def recognize?(_entry); false; end
      def extract(_entry); raise NotImplementedError; end
    end
  end
end
