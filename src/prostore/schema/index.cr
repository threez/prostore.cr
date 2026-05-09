module Prostore
  module Schema
    # An index declaration (ADR-0005).
    #
    # `name` is the resolved index name in the live database — derived by
    # default from `<table>_<columns>_idx`, or set explicitly via the `name:`
    # option. The tag is the stable identity; the name is a label that can
    # change freely.
    record Index,
      tag : Int32,
      name : String,
      columns : Array(String),
      unique : Bool,
      where_sql : String?
  end
end
