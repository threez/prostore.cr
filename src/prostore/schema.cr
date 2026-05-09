require "./schema/field"
require "./schema/index"
require "./schema/foreign_key"
require "./schema/query"

module Prostore
  module Schema
    # The complete schema captured for a single model class.
    #
    # Populated by the macros at compile time and exposed via
    # `Class.prostore_schema`. The diff engine, drift detector, and migration
    # planner consume this struct (and the live DB introspection) to compute
    # the work that needs doing.
    record Definition,
      table_name : String,
      fields : Array(Field),
      indexes : Array(Index),
      foreign_keys : Array(ForeignKey),
      queries : Array(Query),
      reserved_field_tags : Array(Int32),
      reserved_index_tags : Array(Int32),
      reserved_foreign_key_tags : Array(Int32) do
      def field(tag : Int32) : Field?
        fields.find { |field| field.tag == tag }
      end

      def field(name : String) : Field?
        fields.find { |field| field.name == name }
      end

      def field(name : Symbol) : Field?
        field(name.to_s)
      end

      def primary_key : Field?
        fields.find(&.primary)
      end
    end
  end
end
