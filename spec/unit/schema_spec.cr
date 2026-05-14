require "../spec_helper"

# Schema introspection specs (ADR-0014).

private class SpecUser < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :tenant_id, Int64
  reserved 4
  field 5, :nickname, String?
end

private class SpecOrderItem < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
end

private class SpecOverride < Prostore::Model
  table_name "override_table"

  field 1, :id, Int64, primary: true, auto_increment: true
end

private module SpecNs
  class Widget < Prostore::Model
    field 1, :id, Int64, primary: true, auto_increment: true
  end

  class MailQueue < Prostore::Model
    field 1, :id, Int64, primary: true, auto_increment: true
  end
end

private class SpecLiteralDefaults < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :active, Bool, default: false, backfill: false
  field 3, :count, Int32, default: 0, backfill: 0
  field 4, :label, String, default: "none", backfill: "none"
  field 5, :created_at, Time, default: :CURRENT_TIMESTAMP
end

describe "Prostore::Model schema introspection" do
  it "registers every subclass in Prostore.models" do
    Prostore.models.should contain(SpecUser)
    Prostore.models.should contain(SpecOrderItem)
    Prostore.models.should contain(SpecOverride)
  end

  describe "default table name derivation (ADR-0014)" do
    it "snake_cases single-word class names" do
      SpecUser.prostore_table_name.should eq("spec_user")
    end

    it "snake_cases multi-word class names without pluralization" do
      SpecOrderItem.prostore_table_name.should eq("spec_order_item")
    end

    it "honors `table_name` override" do
      SpecOverride.prostore_table_name.should eq("override_table")
    end

    it "replaces :: with _ for module-namespaced classes" do
      SpecNs::Widget.prostore_table_name.should eq("spec_ns_widget")
    end

    it "applies both CamelCase split and :: replacement" do
      SpecNs::MailQueue.prostore_table_name.should eq("spec_ns_mail_queue")
    end
  end

  describe "fields" do
    it "captures tag, name, crystal type, portable type, and nullability" do
      schema = SpecUser.prostore_schema

      id_field = schema.field(:id).not_nil!
      id_field.tag.should eq(1)
      id_field.crystal_type.should eq("Int64")
      id_field.portable_type.should eq("int64")
      id_field.nullable.should be_false
      id_field.primary.should be_true
      id_field.auto_increment.should be_true

      nickname_field = schema.field(:nickname).not_nil!
      nickname_field.tag.should eq(5)
      nickname_field.crystal_type.should eq("String?")
      nickname_field.portable_type.should eq("string")
      nickname_field.nullable.should be_true
    end

    it "captures reserved field tags" do
      SpecUser.prostore_schema.reserved_field_tags.should eq([4])
    end

    it "exposes a primary_key helper" do
      SpecUser.prostore_schema.primary_key.try(&.name).should eq("id")
    end
  end

  describe "scalar literal auto-wrap for default: / backfill:" do
    it "wraps false BoolLiteral as SQL 'false'" do
      f = SpecLiteralDefaults.prostore_schema.field(:active).not_nil!
      f.default_sql.should eq("false")
      f.backfill_sql.should eq("false")
    end

    it "wraps NumberLiteral as SQL integer string" do
      f = SpecLiteralDefaults.prostore_schema.field(:count).not_nil!
      f.default_sql.should eq("0")
      f.backfill_sql.should eq("0")
    end

    it "wraps StringLiteral in SQL single quotes" do
      f = SpecLiteralDefaults.prostore_schema.field(:label).not_nil!
      f.default_sql.should eq("'none'")
      f.backfill_sql.should eq("'none'")
    end

    it "emits SymbolLiteral verbatim as SQL keyword/function" do
      f = SpecLiteralDefaults.prostore_schema.field(:created_at).not_nil!
      f.default_sql.should eq("CURRENT_TIMESTAMP")
    end
  end
end
