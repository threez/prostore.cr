require "../spec_helper"

# Coverage for native enum support (ADR-0016):
# - macro detection + Schema::Field population
# - storage discipline (string default, int opt-in, flags implicit int)
# - DDL CHECK rendering on both adapters
# - fingerprint sensitivity to member set + flags annotation
# - validator: add allowed, remove/value-change rejected
# - diff engine: AlterEnumMembers emitted for additive widening
# - codec round-trip for resume

enum EnumSpecStatus
  Active
  Pending
  Archived
end

enum EnumSpecStatusPlus
  Active
  Pending
  Archived
  Banned
end

enum EnumSpecRank
  Bronze
  Silver =  5
  Gold   = 10
end

@[Flags]
enum EnumSpecPerms
  Read
  Write
  Execute
end

private class EnumModelString < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :status, EnumSpecStatus
end

private class EnumModelInt < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :rank, EnumSpecRank, as: :int
end

private class EnumModelFlags < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :perms, EnumSpecPerms
end

private class EnumModelStringPlus < Prostore::Model
  # Same shape as EnumModelString but with a widened enum member set.
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :status, EnumSpecStatusPlus
end

describe "ADR-0016: native enum support" do
  describe "Schema::Field capture" do
    it "captures string-backed enum metadata" do
      field = EnumModelString.prostore_schema.field("status").not_nil!
      field.portable_type.should eq("enum_string")
      field.enum_is_flags.should be_false
      members = field.enum_members.not_nil!
      members.map(&.name).should eq(["Active", "Pending", "Archived"])
      members.map(&.value).should eq([0_i64, 1_i64, 2_i64])
    end

    it "captures int-backed enum metadata with explicit values" do
      field = EnumModelInt.prostore_schema.field("rank").not_nil!
      field.portable_type.should eq("enum_int")
      field.enum_is_flags.should be_false
      members = field.enum_members.not_nil!
      members.map(&.value).should eq([0_i64, 5_i64, 10_i64])
    end

    it "implicitly int-backs @[Flags] enums and marks them" do
      field = EnumModelFlags.prostore_schema.field("perms").not_nil!
      field.portable_type.should eq("enum_int")
      field.enum_is_flags.should be_true
      field.enum_members.not_nil!.map(&.value).should eq([1_i64, 2_i64, 4_i64])
    end
  end

  describe "fingerprint" do
    it "differs when an enum member is added" do
      base = EnumModelString.prostore_fingerprint
      widened = EnumModelStringPlus.prostore_fingerprint
      base.should_not eq(widened)
    end
  end

  describe "DDL: CHECK constraint" do
    it "renders a named CHECK with the literal member names (string-backed)" do
      field = EnumModelString.prostore_schema.field("status").not_nil!
      out = Prostore::Adapter::SQLite::DDL.render_enum_check(field, "enum_model_string").not_nil!
      out.should contain("'Active'")
      out.should contain("'Pending'")
      out.should contain("'Archived'")
      out.should contain("CONSTRAINT")
      out.should contain("enum_model_string_status_enum_chk")
    end

    it "renders integer IN-list for int-backed enums" do
      field = EnumModelInt.prostore_schema.field("rank").not_nil!
      out = Prostore::Adapter::Postgres::DDL.render_enum_check(field, "enum_model_int").not_nil!
      out.should contain("IN (0, 5, 10)")
    end

    it "renders a bounded range for flags enums (max = bitwise OR of all values)" do
      field = EnumModelFlags.prostore_schema.field("perms").not_nil!
      out = Prostore::Adapter::SQLite::DDL.render_enum_check(field, "enum_model_flags").not_nil!
      # Sum of declared flag values: 1 + 2 + 4 == 7
      out.should contain(">= 0")
      out.should contain("<= 7")
    end

    it "returns nil for non-enum fields" do
      id_field = EnumModelString.prostore_schema.field("id").not_nil!
      Prostore::Adapter::SQLite::DDL.render_enum_check(id_field).should be_nil
    end

    it "embeds the CHECK clause in CREATE TABLE output" do
      sql = Prostore::Adapter::SQLite::DDL.render_create_table(
        EnumModelString.prostore_schema,
        {} of String => Array(String),
      )
      sql.should contain("CONSTRAINT")
      sql.should contain("CHECK")
      sql.should contain("'Active'")
    end
  end

  describe "validator (ADR-0016 evolution discipline)" do
    private_table = "enum_table"

    it "allows adding a member (additive change)" do
      stored_field = EnumModelString.prostore_schema.field("status").not_nil!
      desired_field = EnumModelStringPlus.prostore_schema.field("status").not_nil!

      desired_def = Prostore::Schema::Definition.new(
        table_name: private_table,
        fields: [desired_field],
        indexes: [] of Prostore::Schema::Index,
        foreign_keys: [] of Prostore::Schema::ForeignKey,
        queries: [] of Prostore::Schema::Query,
        reserved_field_tags: [] of Int32,
        reserved_index_tags: [] of Int32,
        reserved_foreign_key_tags: [] of Int32,
      )

      stored_rows = [
        Prostore::Drift::SchemaTable::Row.new(
          table_name: private_table,
          kind: Prostore::Drift::SchemaTable::KIND_COLUMN,
          tag: stored_field.tag,
          current_name: stored_field.name,
          portable_type: stored_field.portable_type,
          nullable: stored_field.nullable,
          primary: stored_field.primary,
          auto_increment: stored_field.auto_increment,
          has_default: stored_field.has_default,
          default_sql: stored_field.default_sql,
          has_backfill: stored_field.has_backfill,
          backfill_sql: stored_field.backfill_sql,
          has_lazy: stored_field.has_lazy,
          enum_members: stored_field.enum_members,
          enum_is_flags: stored_field.enum_is_flags,
        ),
      ]

      Prostore::Diff::Validator.validate_table(desired_def, stored_rows)
    end

    it "rejects removing an enum member" do
      desired_field = EnumModelString.prostore_schema.field("status").not_nil!
      stored_field = EnumModelStringPlus.prostore_schema.field("status").not_nil!

      desired_def = Prostore::Schema::Definition.new(
        table_name: private_table,
        fields: [desired_field],
        indexes: [] of Prostore::Schema::Index,
        foreign_keys: [] of Prostore::Schema::ForeignKey,
        queries: [] of Prostore::Schema::Query,
        reserved_field_tags: [] of Int32,
        reserved_index_tags: [] of Int32,
        reserved_foreign_key_tags: [] of Int32,
      )

      stored_rows = [
        Prostore::Drift::SchemaTable::Row.new(
          table_name: private_table,
          kind: Prostore::Drift::SchemaTable::KIND_COLUMN,
          tag: stored_field.tag,
          current_name: stored_field.name,
          portable_type: stored_field.portable_type,
          nullable: stored_field.nullable,
          primary: stored_field.primary,
          auto_increment: stored_field.auto_increment,
          has_default: stored_field.has_default,
          default_sql: stored_field.default_sql,
          has_backfill: stored_field.has_backfill,
          backfill_sql: stored_field.backfill_sql,
          has_lazy: stored_field.has_lazy,
          enum_members: stored_field.enum_members,
          enum_is_flags: stored_field.enum_is_flags,
        ),
      ]

      expect_raises(Prostore::SchemaError, /enum member.*Banned.*removed/) do
        Prostore::Diff::Validator.validate_table(desired_def, stored_rows)
      end
    end

    it "rejects changing the integer value of an existing member" do
      desired_field = EnumModelInt.prostore_schema.field("rank").not_nil!
      stored_members = [
        Prostore::Schema::EnumMember.new(name: "Bronze", value: 0_i64),
        Prostore::Schema::EnumMember.new(name: "Silver", value: 1_i64), # was 5
        Prostore::Schema::EnumMember.new(name: "Gold", value: 10_i64),
      ]

      desired_def = Prostore::Schema::Definition.new(
        table_name: private_table,
        fields: [desired_field],
        indexes: [] of Prostore::Schema::Index,
        foreign_keys: [] of Prostore::Schema::ForeignKey,
        queries: [] of Prostore::Schema::Query,
        reserved_field_tags: [] of Int32,
        reserved_index_tags: [] of Int32,
        reserved_foreign_key_tags: [] of Int32,
      )

      stored_rows = [
        Prostore::Drift::SchemaTable::Row.new(
          table_name: private_table,
          kind: Prostore::Drift::SchemaTable::KIND_COLUMN,
          tag: desired_field.tag,
          current_name: desired_field.name,
          portable_type: desired_field.portable_type,
          nullable: desired_field.nullable,
          primary: desired_field.primary,
          auto_increment: desired_field.auto_increment,
          has_default: desired_field.has_default,
          default_sql: desired_field.default_sql,
          has_backfill: desired_field.has_backfill,
          backfill_sql: desired_field.backfill_sql,
          has_lazy: desired_field.has_lazy,
          enum_members: stored_members,
          enum_is_flags: false,
        ),
      ]

      expect_raises(Prostore::SchemaError, /Silver.*value changed/) do
        Prostore::Diff::Validator.validate_table(desired_def, stored_rows)
      end
    end
  end

  describe "diff engine" do
    it "emits AlterEnumMembers when the desired set strictly contains the stored set" do
      desired_field = EnumModelStringPlus.prostore_schema.field("status").not_nil!
      stored_field = EnumModelString.prostore_schema.field("status").not_nil!

      desired_def = Prostore::Schema::Definition.new(
        table_name: "enum_table",
        fields: [desired_field],
        indexes: [] of Prostore::Schema::Index,
        foreign_keys: [] of Prostore::Schema::ForeignKey,
        queries: [] of Prostore::Schema::Query,
        reserved_field_tags: [] of Int32,
        reserved_index_tags: [] of Int32,
        reserved_foreign_key_tags: [] of Int32,
      )

      stored_rows = [
        Prostore::Drift::SchemaTable::Row.new(
          table_name: "enum_table",
          kind: Prostore::Drift::SchemaTable::KIND_COLUMN,
          tag: stored_field.tag,
          current_name: stored_field.name,
          portable_type: stored_field.portable_type,
          nullable: stored_field.nullable,
          primary: stored_field.primary,
          auto_increment: stored_field.auto_increment,
          has_default: stored_field.has_default,
          default_sql: stored_field.default_sql,
          has_backfill: stored_field.has_backfill,
          backfill_sql: stored_field.backfill_sql,
          has_lazy: stored_field.has_lazy,
          enum_members: stored_field.enum_members,
          enum_is_flags: stored_field.enum_is_flags,
        ),
      ]

      ops = Prostore::Diff::Engine.diff_table(desired_def, stored_rows)
      ops.any?(Prostore::Diff::Operation::AlterEnumMembers).should be_true
    end

    it "emits no AlterEnumMembers when the member set is unchanged" do
      stored_field = EnumModelString.prostore_schema.field("status").not_nil!

      desired_def = Prostore::Schema::Definition.new(
        table_name: "enum_table",
        fields: [stored_field],
        indexes: [] of Prostore::Schema::Index,
        foreign_keys: [] of Prostore::Schema::ForeignKey,
        queries: [] of Prostore::Schema::Query,
        reserved_field_tags: [] of Int32,
        reserved_index_tags: [] of Int32,
        reserved_foreign_key_tags: [] of Int32,
      )

      stored_rows = [
        Prostore::Drift::SchemaTable::Row.new(
          table_name: "enum_table",
          kind: Prostore::Drift::SchemaTable::KIND_COLUMN,
          tag: stored_field.tag,
          current_name: stored_field.name,
          portable_type: stored_field.portable_type,
          nullable: stored_field.nullable,
          primary: stored_field.primary,
          auto_increment: stored_field.auto_increment,
          has_default: stored_field.has_default,
          default_sql: stored_field.default_sql,
          has_backfill: stored_field.has_backfill,
          backfill_sql: stored_field.backfill_sql,
          has_lazy: stored_field.has_lazy,
          enum_members: stored_field.enum_members,
          enum_is_flags: stored_field.enum_is_flags,
        ),
      ]

      ops = Prostore::Diff::Engine.diff_table(desired_def, stored_rows)
      ops.none?(Prostore::Diff::Operation::AlterEnumMembers).should be_true
    end
  end

  describe "codec round-trip" do
    it "preserves enum_members and enum_is_flags across encode/decode" do
      field = EnumModelFlags.prostore_schema.field("perms").not_nil!
      step = Prostore::Steps::Kind::AlterEnumMembers.new("enum_table", field)
      encoded = Prostore::Steps::Codec.encode(step)
      decoded = Prostore::Steps::Codec.decode(encoded[:kind], encoded[:params]).as(Prostore::Steps::Kind::AlterEnumMembers)
      decoded.table_name.should eq("enum_table")
      decoded.field.enum_is_flags.should be_true
      decoded.field.enum_members.not_nil!.map(&.name).should eq(["Read", "Write", "Execute"])
      decoded.field.enum_members.not_nil!.map(&.value).should eq([1_i64, 2_i64, 4_i64])
    end
  end
end
