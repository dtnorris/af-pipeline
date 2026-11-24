# frozen_string_literal: true
module AfDataPipeline
  class AdapterRegistry
    attr_reader :adapters
    def initialize(adapters: nil); @adapters=adapters || [Adapters::CanonicalJsonV01.new]; end
    def adapter_for(entry); adapters.find { |a| a.recognize?(entry) }; end
  end
end
