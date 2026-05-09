require "../spec_helper"

# Type mapping specs (ADR-0014 portable type set).

private class SpecAllTypes < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :i32_col, Int32
  field 3, :i64_col, Int64
  field 4, :f32_col, Float32
  field 5, :f64_col, Float64
  field 6, :str_col, String
  field 7, :bool_col, Bool
  field 8, :time_col, Time
  field 9, :bytes_col, Bytes
  field 10, :nullable_str, String?
  field 11, :nullable_int, Int32?
end

describe "Prostore type mapping (ADR-0014)" do
  it "maps every portable type" do
    schema = SpecAllTypes.prostore_schema

    schema.field(:i32_col).not_nil!.portable_type.should eq("int32")
    schema.field(:i64_col).not_nil!.portable_type.should eq("int64")
    schema.field(:f32_col).not_nil!.portable_type.should eq("float32")
    schema.field(:f64_col).not_nil!.portable_type.should eq("float64")
    schema.field(:str_col).not_nil!.portable_type.should eq("string")
    schema.field(:bool_col).not_nil!.portable_type.should eq("bool")
    schema.field(:time_col).not_nil!.portable_type.should eq("time")
    schema.field(:bytes_col).not_nil!.portable_type.should eq("bytes")
  end

  it "decomposes T? into base + nullable" do
    schema = SpecAllTypes.prostore_schema

    nullable_str = schema.field(:nullable_str).not_nil!
    nullable_str.portable_type.should eq("string")
    nullable_str.nullable.should be_true
    nullable_str.crystal_type.should eq("String?")

    nullable_int = schema.field(:nullable_int).not_nil!
    nullable_int.portable_type.should eq("int32")
    nullable_int.nullable.should be_true
  end

  it "marks non-nullable types correctly" do
    schema = SpecAllTypes.prostore_schema
    schema.field(:str_col).not_nil!.nullable.should be_false
    schema.field(:i32_col).not_nil!.nullable.should be_false
  end
end
