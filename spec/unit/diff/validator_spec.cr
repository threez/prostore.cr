require "../../spec_helper"

# Diff validator unit specs (ADR-0003/0011/0005).

private alias Row = Prostore::Drift::SchemaTable::Row

private def column_row(table : String, tag : Int32, name : String, **attrs) : Row
  default = {
    portable_type:  "string",
    nullable:       false,
    primary:        false,
    auto_increment: false,
    has_default:    false,
    default_sql:    nil,
    has_backfill:   false,
    backfill_sql:   nil,
    has_lazy:       false,
  }
  merged = default.merge(attrs)
  Row.new(table, "column", tag, name, merged.to_json)
end

private def index_row(table : String, tag : Int32, name : String, **attrs) : Row
  default = {columns: [] of String, unique: false, where_sql: nil}
  merged = default.merge(attrs)
  Row.new(table, "index", tag, name, merged.to_json)
end

private class TypeChangeBefore < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :col, String
end

private class TypeChangeAfter < Prostore::Model
  table_name "type_change"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :col, Int32 # changed from String
end

private class NullabilityAfter < Prostore::Model
  table_name "type_change"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :col, String? # was non-nullable
end

private class NonNullableAdd < Prostore::Model
  table_name "type_change"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :col, String
  field 3, :must_have, String # non-nullable, no default, no backfill
end

private class NonNullableAddOk < Prostore::Model
  table_name "type_change"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :col, String
  field 3, :status, String, default: Prostore::SQL.expr("'active'"), backfill: Prostore::SQL.expr("'active'")
end

private class IndexColChangeAfter < Prostore::Model
  table_name "type_change"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :col, String

  index 1, [:col, :id] # was [:col]
end

describe Prostore::Diff::Validator do
  describe "type changes (ADR-0003)" do
    it "rejects in-place portable_type change" do
      rows = [
        column_row("type_change", 1, "id", portable_type: "int64", primary: true, auto_increment: true),
        column_row("type_change", 2, "col", portable_type: "string"),
      ]
      expect_raises(Prostore::SchemaError, /type changed from string to int32/) do
        Prostore::Diff::Validator.validate([TypeChangeAfter] of Prostore::Model.class, rows)
      end
    end

    it "rejects in-place nullability change" do
      rows = [
        column_row("type_change", 1, "id", portable_type: "int64", primary: true, auto_increment: true),
        column_row("type_change", 2, "col", portable_type: "string", nullable: false),
      ]
      expect_raises(Prostore::SchemaError, /nullability changed/) do
        Prostore::Diff::Validator.validate([NullabilityAfter] of Prostore::Model.class, rows)
      end
    end
  end

  describe "non-nullable add (ADR-0011)" do
    it "rejects adding a non-nullable column with no default and no backfill" do
      rows = [
        column_row("type_change", 1, "id", portable_type: "int64", primary: true, auto_increment: true),
        column_row("type_change", 2, "col", portable_type: "string"),
      ]
      expect_raises(Prostore::SchemaError, /adding a non-nullable column to an existing table/) do
        Prostore::Diff::Validator.validate([NonNullableAdd] of Prostore::Model.class, rows)
      end
    end

    it "permits adding a non-nullable column with a SQL.expr default" do
      rows = [
        column_row("type_change", 1, "id", portable_type: "int64", primary: true, auto_increment: true),
        column_row("type_change", 2, "col", portable_type: "string"),
      ]
      Prostore::Diff::Validator.validate([NonNullableAddOk] of Prostore::Model.class, rows)
    end
  end

  describe "index definition changes (ADR-0005)" do
    it "rejects column-set change on the same index tag" do
      rows = [
        column_row("type_change", 1, "id", portable_type: "int64", primary: true, auto_increment: true),
        column_row("type_change", 2, "col", portable_type: "string"),
        index_row("type_change", 1, "type_change_col_idx", columns: ["col"], unique: false),
      ]
      expect_raises(Prostore::SchemaError, /column set changed/) do
        Prostore::Diff::Validator.validate([IndexColChangeAfter] of Prostore::Model.class, rows)
      end
    end
  end
end
