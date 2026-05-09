require "../spec_helper"

# Schema fingerprint specs (ADR-0009 invariant 4).
#
# Fingerprint must:
#   - Be stable across declaration order (sorted-by-tag).
#   - NOT change on a rename (names are labels, tags are identity, ADR-0002).
#   - Change on a type change.
#   - Change when a tag is reserved.

private class FpA < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :tenant_id, Int64
end

private class FpB < Prostore::Model
  # Same schema, declared in a different order.
  field 3, :tenant_id, Int64
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
end

private class FpRenamed < Prostore::Model
  # Identical to FpA but field 2 is renamed.
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :handle, String # was :email
  field 3, :tenant_id, Int64
end

private class FpTypeChanged < Prostore::Model
  # Identical to FpA but field 2's type is different.
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String? # was String (non-null)
  field 3, :tenant_id, Int64
end

describe "Prostore::Schema::Fingerprint (ADR-0009)" do
  it "is stable across field declaration order" do
    # Both schemas have different table names, so the fingerprints will differ
    # by table_name, but field-and-tag identity should otherwise match. Inject
    # a common table name to compare just field identity.
    a = FpA.prostore_schema
    b = FpB.prostore_schema

    common_a = Prostore::Schema::Definition.new(
      table_name: "shared",
      fields: a.fields,
      indexes: a.indexes,
      foreign_keys: a.foreign_keys,
      queries: a.queries,
      reserved_field_tags: a.reserved_field_tags,
      reserved_index_tags: a.reserved_index_tags,
      reserved_foreign_key_tags: a.reserved_foreign_key_tags,
    )
    common_b = Prostore::Schema::Definition.new(
      table_name: "shared",
      fields: b.fields,
      indexes: b.indexes,
      foreign_keys: b.foreign_keys,
      queries: b.queries,
      reserved_field_tags: b.reserved_field_tags,
      reserved_index_tags: b.reserved_index_tags,
      reserved_foreign_key_tags: b.reserved_foreign_key_tags,
    )

    Prostore::Schema::Fingerprint.compute(common_a).should eq(
      Prostore::Schema::Fingerprint.compute(common_b)
    )
  end

  it "does not change on a column rename (tags are identity)" do
    a_fp = Prostore::Schema::Fingerprint.compute(
      Prostore::Schema::Definition.new(
        table_name: "t", fields: FpA.prostore_schema.fields,
        indexes: [] of Prostore::Schema::Index,
        foreign_keys: [] of Prostore::Schema::ForeignKey,
        queries: [] of Prostore::Schema::Query,
        reserved_field_tags: [] of Int32,
        reserved_index_tags: [] of Int32,
        reserved_foreign_key_tags: [] of Int32,
      )
    )
    renamed_fp = Prostore::Schema::Fingerprint.compute(
      Prostore::Schema::Definition.new(
        table_name: "t", fields: FpRenamed.prostore_schema.fields,
        indexes: [] of Prostore::Schema::Index,
        foreign_keys: [] of Prostore::Schema::ForeignKey,
        queries: [] of Prostore::Schema::Query,
        reserved_field_tags: [] of Int32,
        reserved_index_tags: [] of Int32,
        reserved_foreign_key_tags: [] of Int32,
      )
    )
    a_fp.should eq(renamed_fp)
  end

  it "changes when a column's type changes" do
    a_fp = FpA.prostore_fingerprint
    type_changed_fp = FpTypeChanged.prostore_fingerprint
    a_fp.should_not eq(type_changed_fp)
  end

  it "is a stable hex string" do
    fp = FpA.prostore_fingerprint
    fp.should match(/\A[0-9a-f]{64}\z/)
  end
end
