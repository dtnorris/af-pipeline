# frozen_string_literal: true
module AfDataPipeline
  class Normalizer
    Result=Struct.new(:records,:recognized_files,:unrecognized_files,:errors,keyword_init:true)
    def initialize(registry: AdapterRegistry.new); @registry=registry; end
    def normalize(entries)
      records=[]; recognized=[]; unrecognized=[]; errors=[]
      entries.each do |entry|
        adapter=@registry.adapter_for(entry)
        unless adapter; unrecognized << entry.relative_path; next; end
        begin
          extracted=adapter.extract(entry); records.concat(extracted); recognized << {"path"=>entry.relative_path,"adapter"=>adapter.name,"records"=>extracted.length}
        rescue Error, JSON::ParserError => e
          errors << {"path"=>entry.relative_path,"adapter"=>adapter.name,"error"=>e.message}
        end
      end
      Result.new(records:records,recognized_files:recognized,unrecognized_files:unrecognized,errors:errors)
    end
  end
end
