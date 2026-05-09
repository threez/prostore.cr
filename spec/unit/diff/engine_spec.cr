require "../../spec_helper"

# Diff engine unit specs (ADR-0001/0002/0008).
#
# The engine is a pure function over (model definitions, prostore_schema
# rows). These tests construct synthetic inputs without touching a DB.

private class BeforeThing < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String

  index 1, [:email], unique: true
end

private class AfterThing < Prostore::Model
  table_name "before_thing" # share the table so the diff compares schemas, not tables

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :handle, String # renamed from :email
  field 3, :score, Int32?

  index 1, [:handle], unique: true # renamed
  index 2, [:score]
end

private class DroppedThing < Prostore::Model
  table_name "before_thing"

  field 1, :id, Int64, primary: true, auto_increment: true
  reserved 2       # was email/handle
  reserved_index 1 # was email_idx
end

private alias OP = Prostore::Diff::Operation
private alias Row = Prostore::Drift::SchemaTable::Row

private class TopoParent < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
end

private class TopoChild < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64

  foreign_key 1, [:parent_id], references: TopoParent
end

private class TopoSelfRef < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :parent_id, Int64?

  foreign_key 1, [:parent_id], references: TopoSelfRef
end

private def schema_rows_for_before : Array(Row)
  [
    Row.new("before_thing", "column", 1, "id",
      {portable_type: "int64", nullable: false, primary: true, auto_increment: true,
       has_default: false, default_sql: nil, has_backfill: false, backfill_sql: nil,
       has_lazy: false}.to_json),
    Row.new("before_thing", "column", 2, "email",
      {portable_type: "string", nullable: false, primary: false, auto_increment: false,
       has_default: false, default_sql: nil, has_backfill: false, backfill_sql: nil,
       has_lazy: false}.to_json),
    Row.new("before_thing", "index", 1, "before_thing_email_idx",
      {columns: ["email"], unique: true, where_sql: nil}.to_json),
  ]
end

describe Prostore::Diff::Engine do
  it "emits CreateTable for tables not yet in prostore_schema" do
    rows = [] of Row
    ops = Prostore::Diff::Engine.diff([BeforeThing] of Prostore::Model.class, rows)
    ops.size.should eq(1)
    ops.first.should be_a(OP::CreateTable)
  end

  it "emits no operations when desired matches actual" do
    ops = Prostore::Diff::Engine.diff([BeforeThing] of Prostore::Model.class, schema_rows_for_before)
    ops.should be_empty
  end

  it "emits AddField for new tags" do
    ops = Prostore::Diff::Engine.diff([AfterThing] of Prostore::Model.class, schema_rows_for_before)
    adds = ops.select(OP::AddField).map(&.as(OP::AddField))
    adds.size.should eq(1)
    adds.first.field.tag.should eq(3)
    adds.first.field.name.should eq("score")
  end

  it "emits RenameField when same tag but different name" do
    ops = Prostore::Diff::Engine.diff([AfterThing] of Prostore::Model.class, schema_rows_for_before)
    renames = ops.select(OP::RenameField).map(&.as(OP::RenameField))
    renames.size.should eq(1)
    renames.first.tag.should eq(2)
    renames.first.from_name.should eq("email")
    renames.first.to_name.should eq("handle")
  end

  it "emits DropField when tag is reserved and existed previously" do
    ops = Prostore::Diff::Engine.diff([DroppedThing] of Prostore::Model.class, schema_rows_for_before)
    drops = ops.select(OP::DropField).map(&.as(OP::DropField))
    drops.size.should eq(1)
    drops.first.tag.should eq(2)
    drops.first.current_name.should eq("email")
  end

  it "raises if a column exists but is neither declared nor reserved" do
    rows = schema_rows_for_before
    expect_raises(Prostore::SchemaError, /neither declared nor reserved/) do
      Prostore::Diff::Engine.diff([BeforeThing.new.class] of Prostore::Model.class, rows + [
        Row.new("before_thing", "column", 99, "ghost",
          {portable_type: "string", nullable: true, primary: false, auto_increment: false,
           has_default: false, default_sql: nil, has_backfill: false, backfill_sql: nil,
           has_lazy: false}.to_json),
      ])
    end
  end

  describe "topological CreateTable ordering" do
    it "creates referenced tables before referrers, regardless of input order" do
      parent_klass = TopoParent
      child_klass = TopoChild

      ops = Prostore::Diff::Engine.diff(
        [child_klass, parent_klass] of Prostore::Model.class,
        [] of Row,
      )

      tables = ops.select(OP::CreateTable)
        .map(&.as(OP::CreateTable))
        .map(&.definition.table_name)

      tables.index!("topo_parent").should be < tables.index!("topo_child")
    end

    it "tolerates a self-referencing foreign key" do
      ops = Prostore::Diff::Engine.diff(
        [TopoSelfRef] of Prostore::Model.class,
        [] of Row,
      )
      ops.size.should eq(1)
      ops.first.should be_a(OP::CreateTable)
    end
  end

  it "emits AddIndex / RenameIndex per the index diff" do
    ops = Prostore::Diff::Engine.diff([AfterThing] of Prostore::Model.class, schema_rows_for_before)
    adds = ops.select(OP::AddIndex).map(&.as(OP::AddIndex))
    adds.size.should eq(1)
    adds.first.index.tag.should eq(2)

    renames = ops.select(OP::RenameIndex).map(&.as(OP::RenameIndex))
    renames.size.should eq(1)
    renames.first.tag.should eq(1)
    renames.first.from_name.should eq("before_thing_email_idx")
    renames.first.to_name.should eq("before_thing_handle_idx")
  end
end
