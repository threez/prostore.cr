require "../../spec_helper"

# Step planner unit specs.

private alias OP = Prostore::Diff::Operation
private alias K = Prostore::Steps::Kind

private def make_field(tag : Int32, name : Symbol, *,
                       portable_type : String = "string",
                       nullable : Bool = false,
                       has_default : Bool = false,
                       default_sql : String? = nil,
                       has_backfill : Bool = false,
                       backfill_sql : String? = nil) : Prostore::Schema::Field
  Prostore::Schema::Field.new(
    tag: tag,
    name: name.to_s,
    crystal_type: nullable ? "String?" : "String",
    portable_type: portable_type,
    nullable: nullable,
    primary: false,
    auto_increment: false,
    has_default: has_default,
    default_sql: default_sql,
    has_backfill: has_backfill,
    backfill_sql: backfill_sql,
    has_lazy: false,
  )
end

private def make_index(tag : Int32, name : String, columns : Array(Symbol)) : Prostore::Schema::Index
  Prostore::Schema::Index.new(
    tag: tag, name: name, columns: columns.map(&.to_s),
    unique: false, where_sql: nil,
  )
end

describe Prostore::Steps::Planner do
  it "maps nullable AddField → AddColumn (single step)" do
    ops = [OP::AddField.new("t", make_field(2, :email, nullable: true))] of OP::Any
    steps = Prostore::Steps::Planner.plan(ops)
    steps.size.should eq(1)
    steps.first.should be_a(K::AddColumn)
  end

  it "maps DropField → DropColumn" do
    ops = [OP::DropField.new("t", 2, "email")] of OP::Any
    steps = Prostore::Steps::Planner.plan(ops)
    steps.size.should eq(1)
    steps.first.should be_a(K::DropColumn)
  end

  it "maps RenameField → RenameColumn" do
    ops = [OP::RenameField.new("t", 2, "email", "handle")] of OP::Any
    steps = Prostore::Steps::Planner.plan(ops)
    steps.size.should eq(1)
    steps.first.should be_a(K::RenameColumn)
  end

  it "maps AddIndex → AddIndex step" do
    ops = [OP::AddIndex.new("t", make_index(1, "t_email_idx", [:email]))] of OP::Any
    steps = Prostore::Steps::Planner.plan(ops)
    steps.size.should eq(1)
    steps.first.should be_a(K::AddIndex)
  end

  it "preserves operation order in the resulting step list" do
    ops = [
      OP::AddField.new("t", make_field(2, :a, nullable: true)),
      OP::AddField.new("t", make_field(3, :b, nullable: true)),
      OP::RenameField.new("t", 2, "old", "a"),
    ] of OP::Any
    steps = Prostore::Steps::Planner.plan(ops)
    steps.size.should eq(3)
  end

  it "marks atomic kinds as transactional" do
    Prostore::Steps.requires_transaction?(K::AddColumn.new("t", make_field(2, :a, nullable: true))).should be_true
    Prostore::Steps.requires_transaction?(K::DropColumn.new("t", 2, "a")).should be_true
    Prostore::Steps.requires_transaction?(K::AddIndex.new("t", make_index(1, "i", [:a]))).should be_true
  end

  describe "multi-phase decomposition" do
    it "single-step when default and backfill coincide" do
      f = Prostore::Schema::Field.new(
        tag: 5, name: "flag",
        crystal_type: "Bool", portable_type: "bool", nullable: false,
        primary: false, auto_increment: false,
        has_default: true, default_sql: "0",
        has_backfill: true, backfill_sql: "0",
        has_lazy: false,
      )
      steps = Prostore::Steps::Planner.plan([OP::AddField.new("t", f)] of OP::Any)
      steps.size.should eq(1)
      steps.first.should be_a(K::AddColumn)
    end

    it "decomposes into AddColumnNullable + BackfillSqlExpr + ApplyNotNull when default and backfill differ" do
      f = Prostore::Schema::Field.new(
        tag: 4, name: "status",
        crystal_type: "String", portable_type: "string", nullable: false,
        primary: false, auto_increment: false,
        has_default: true, default_sql: "'active'",
        has_backfill: true, backfill_sql: "legacy_status",
        has_lazy: false,
      )
      steps = Prostore::Steps::Planner.plan([OP::AddField.new("t", f)] of OP::Any)
      steps.size.should eq(3)
      steps[0].should be_a(K::AddColumnNullable)
      steps[1].should be_a(K::BackfillSqlExpr)
      steps[2].should be_a(K::ApplyNotNull)
    end

    it "raises if non-nullable field has no default and no backfill" do
      f = Prostore::Schema::Field.new(
        tag: 6, name: "x",
        crystal_type: "String", portable_type: "string", nullable: false,
        primary: false, auto_increment: false,
        has_default: false, default_sql: nil,
        has_backfill: false, backfill_sql: nil,
        has_lazy: false,
      )
      expect_raises(Prostore::SchemaError, /without a backfill/) do
        Prostore::Steps::Planner.plan([OP::AddField.new("t", f)] of OP::Any)
      end
    end
  end
end
