require "../../spec_helper"
require "../../../src/prostore/tui/column_types"

# Pure unit coverage for the TUI ColumnTypes predicates added alongside
# native enum support. Each predicate is exercised in two modes:
#   - with the portable_type tag present (the precise path the bookkeeping
#     table feeds us)
#   - with portable_type nil, falling back to SQL type_text inference (the
#     path for databases not managed by prostore).

describe Prostore::TUI::ColumnTypes do
  describe ".bool?" do
    it "matches the bool portable tag" do
      Prostore::TUI::ColumnTypes.bool?("bool", "INTEGER").should be_true
    end

    it "falls back to type_text when portable_type is nil" do
      Prostore::TUI::ColumnTypes.bool?(nil, "BOOLEAN").should be_true
      Prostore::TUI::ColumnTypes.bool?(nil, "BOOL").should be_true
      Prostore::TUI::ColumnTypes.bool?(nil, "INTEGER").should be_false
    end
  end

  describe ".enum?" do
    it "matches enum_string and enum_int portable tags" do
      Prostore::TUI::ColumnTypes.enum?("enum_string").should be_true
      Prostore::TUI::ColumnTypes.enum?("enum_int").should be_true
    end

    it "is false for non-enum tags" do
      Prostore::TUI::ColumnTypes.enum?("string").should be_false
      Prostore::TUI::ColumnTypes.enum?("int32").should be_false
      Prostore::TUI::ColumnTypes.enum?("bool").should be_false
      Prostore::TUI::ColumnTypes.enum?(nil).should be_false
    end
  end

  describe ".enum_string? / .enum_int?" do
    it "discriminates the two enum backings" do
      Prostore::TUI::ColumnTypes.enum_string?("enum_string").should be_true
      Prostore::TUI::ColumnTypes.enum_string?("enum_int").should be_false
      Prostore::TUI::ColumnTypes.enum_int?("enum_int").should be_true
      Prostore::TUI::ColumnTypes.enum_int?("enum_string").should be_false
    end
  end

  describe ".int?" do
    it "matches int32/int64 portable tags" do
      Prostore::TUI::ColumnTypes.int?("int32", "TEXT").should be_true
      Prostore::TUI::ColumnTypes.int?("int64", "TEXT").should be_true
    end

    it "falls back to type_text" do
      Prostore::TUI::ColumnTypes.int?(nil, "INTEGER").should be_true
      Prostore::TUI::ColumnTypes.int?(nil, "BIGINT").should be_true
      Prostore::TUI::ColumnTypes.int?(nil, "SERIAL").should be_true
      Prostore::TUI::ColumnTypes.int?(nil, "TEXT").should be_false
    end

    it "is false for non-int portable tags" do
      Prostore::TUI::ColumnTypes.int?("string", "TEXT").should be_false
      Prostore::TUI::ColumnTypes.int?("bool", "INTEGER").should be_false
    end
  end

  describe ".float?" do
    it "matches float32/float64 portable tags" do
      Prostore::TUI::ColumnTypes.float?("float32", "TEXT").should be_true
      Prostore::TUI::ColumnTypes.float?("float64", "TEXT").should be_true
    end

    it "falls back to type_text" do
      Prostore::TUI::ColumnTypes.float?(nil, "REAL").should be_true
      Prostore::TUI::ColumnTypes.float?(nil, "DOUBLE PRECISION").should be_true
      Prostore::TUI::ColumnTypes.float?(nil, "FLOAT").should be_true
      Prostore::TUI::ColumnTypes.float?(nil, "INTEGER").should be_false
    end
  end

  describe ".decimal?" do
    it "matches the decimal portable tag" do
      Prostore::TUI::ColumnTypes.decimal?("decimal", "TEXT").should be_true
    end

    it "falls back to type_text" do
      Prostore::TUI::ColumnTypes.decimal?(nil, "NUMERIC").should be_true
      Prostore::TUI::ColumnTypes.decimal?(nil, "DECIMAL(10,2)").should be_true
      Prostore::TUI::ColumnTypes.decimal?(nil, "INTEGER").should be_false
    end
  end

  describe ".numeric?" do
    it "is true for any of int / float / decimal" do
      Prostore::TUI::ColumnTypes.numeric?("int32", "").should be_true
      Prostore::TUI::ColumnTypes.numeric?("float64", "").should be_true
      Prostore::TUI::ColumnTypes.numeric?("decimal", "").should be_true
    end

    it "is false for non-numeric tags" do
      Prostore::TUI::ColumnTypes.numeric?("string", "TEXT").should be_false
      Prostore::TUI::ColumnTypes.numeric?("bool", "BOOLEAN").should be_false
      Prostore::TUI::ColumnTypes.numeric?("enum_string", "TEXT").should be_false
    end
  end
end
