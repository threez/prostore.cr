module Prostore
  module Schema
    # A foreign-key declaration (ADR-0012).
    #
    # `references_table` is captured as a string (the target model's resolved
    # table name) so the schema struct does not hold a class reference.
    # Resolution to the actual target column happens at planner time —
    # `references_columns` may be empty when the user did not pass
    # `references_fields:`, in which case the planner resolves to the target
    # table's primary key.
    ACTIONS = [:no_action, :restrict, :cascade, :set_null, :set_default]

    record ForeignKey,
      tag : Int32,
      name : String,
      columns : Array(String),
      references_table : String,
      references_columns : Array(String),
      on_delete : Symbol,
      on_update : Symbol
  end
end
