module Prostore
  module Adapter
    # Intermediate types describing what introspection sees in the live
    # database — names only, no tags. The drift detector reconciles these
    # against `prostore_schema` (which carries tags) to produce a tag-keyed
    # view; the diff engine then operates against that.

    record LiveColumn,
      name : String,
      type_text : String,
      nullable : Bool,
      default_text : String?,
      primary : Bool,
      auto_increment : Bool

    record LiveIndex,
      name : String,
      columns : Array(String),
      unique : Bool,
      where_sql : String?

    record LiveForeignKey,
      name : String,
      columns : Array(String),
      references_table : String,
      references_columns : Array(String),
      on_delete : Symbol,
      on_update : Symbol

    record LiveTable,
      name : String,
      columns : Array(LiveColumn),
      indexes : Array(LiveIndex),
      foreign_keys : Array(LiveForeignKey)
  end
end
