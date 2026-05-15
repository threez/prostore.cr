require "./spec_helper"

# Internal-schema migration specs (prostore_meta + v2 split_definitions).
#
# Covers:
#   - fresh install: bookkeeping tables come up in the v2 shape and
#     prostore_meta records schema_version=2 without running the step
#   - legacy install: a hand-built v1 prostore_schema (with the old
#     `definition` JSON column) is upgraded to v2 in place, preserving
#     all encoded values
#   - quiescence guard: an in-flight migration row prevents the upgrade

private class IMUser < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
end

private def adapter_meta_table(conn : Prostore::Connection) : String
  conn.adapter.quote_ident(Prostore::Migration::Bookkeeping::META_TABLE)
end

private def schema_version(backend : TestBackend, conn : Prostore::Connection) : Int32?
  raw = backend.query_one?(
    conn,
    "SELECT value FROM #{adapter_meta_table(conn)} WHERE key = ?",
    "schema_version",
    as: String
  )
  raw.try(&.to_i32?)
end

private def install_legacy_v1(backend : TestBackend, conn : Prostore::Connection) : Nil
  qt = conn.adapter.quote_ident(Prostore::Migration::Bookkeeping::SCHEMA_TABLE)
  # Create the v1 layout directly — minimal columns + JSON definition.
  conn.db.exec <<-SQL
    CREATE TABLE #{qt} (
      table_name    TEXT    NOT NULL,
      kind          TEXT    NOT NULL,
      tag           INTEGER NOT NULL,
      current_name  TEXT    NOT NULL,
      definition    TEXT    NOT NULL,
      PRIMARY KEY (table_name, kind, tag)
    )
  SQL

  field_defn = {
    portable_type:  "int64",
    nullable:       false,
    primary:        true,
    auto_increment: true,
    has_default:    false,
    default_sql:    nil,
    has_backfill:   false,
    backfill_sql:   nil,
    has_lazy:       false,
  }.to_json
  email_defn = {
    portable_type:  "string",
    nullable:       false,
    primary:        false,
    auto_increment: false,
    has_default:    false,
    default_sql:    nil,
    has_backfill:   false,
    backfill_sql:   nil,
    has_lazy:       false,
  }.to_json
  idx_defn = {
    columns:   ["email"],
    unique:    true,
    where_sql: nil,
  }.to_json

  backend.exec(conn, "INSERT INTO #{qt} (table_name, kind, tag, current_name, definition) VALUES (?, ?, ?, ?, ?)",
    "im_user", "column", 1, "id", field_defn)
  backend.exec(conn, "INSERT INTO #{qt} (table_name, kind, tag, current_name, definition) VALUES (?, ?, ?, ?, ?)",
    "im_user", "column", 2, "email", email_defn)
  backend.exec(conn, "INSERT INTO #{qt} (table_name, kind, tag, current_name, definition) VALUES (?, ?, ?, ?, ?)",
    "im_user", "index", 1, "im_user_email_idx", idx_defn)
end

BACKENDS.each do |backend|
  describe "#{backend.name}: Internal.run — fresh install" do
    it "writes schema_version=2 to prostore_meta on first run" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [IMUser] of Prostore::Model.class)
        schema_version(backend, conn).should eq(Prostore::Migration::Internal::CURRENT_SCHEMA_VERSION)
      end
    end

    it "creates prostore_schema with typed columns (no `definition`)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [IMUser] of Prostore::Model.class)
        live = conn.adapter.introspect_table(Prostore::Migration::Bookkeeping::SCHEMA_TABLE)
        col_names = live.columns.map(&.name)
        col_names.should contain("portable_type")
        col_names.should contain("nullable")
        col_names.should_not contain("definition")
      end
    end

    it "is idempotent (running twice doesn't bump version)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [IMUser] of Prostore::Model.class)
        Prostore::Migration::Runner.migrate(conn, [IMUser] of Prostore::Model.class)
        schema_version(backend, conn).should eq(Prostore::Migration::Internal::CURRENT_SCHEMA_VERSION)
      end
    end
  end

  describe "#{backend.name}: Internal.run — legacy v1 upgrade" do
    it "lifts JSON definition into typed columns, preserving values" do
      backend.with_connection do |conn|
        install_legacy_v1(backend, conn)

        Prostore::Migration::Internal.run(conn.adapter, conn.db)

        schema_version(backend, conn).should eq(Prostore::Migration::Internal::CURRENT_SCHEMA_VERSION)

        rows = Prostore::Drift::SchemaTable.for_table(conn.adapter, conn.db, "im_user")
        id_row = rows.find! { |row| row.kind == "column" && row.tag == 1 }
        id_row.portable_type.should eq("int64")
        id_row.primary.should eq(true)
        id_row.auto_increment.should eq(true)
        id_row.nullable.should eq(false)

        email_row = rows.find! { |row| row.kind == "column" && row.tag == 2 }
        email_row.portable_type.should eq("string")
        email_row.primary.should eq(false)
        email_row.nullable.should eq(false)

        idx_row = rows.find! { |row| row.kind == "index" && row.tag == 1 }
        idx_row.index_columns.should eq(["email"])
        idx_row.index_unique.should eq(true)
        idx_row.index_where_sql.should be_nil
      end
    end

    it "drops the legacy `definition` column after upgrade" do
      backend.with_connection do |conn|
        install_legacy_v1(backend, conn)
        Prostore::Migration::Internal.run(conn.adapter, conn.db)

        live = conn.adapter.introspect_table(Prostore::Migration::Bookkeeping::SCHEMA_TABLE)
        live.columns.map(&.name).should_not contain("definition")
      end
    end
  end

  describe "#{backend.name}: Internal.run — quiescence guard" do
    it "refuses to upgrade when a user migration is in flight" do
      backend.with_connection do |conn|
        # Set up the legacy shape and a pending migration row.
        install_legacy_v1(backend, conn)
        Prostore::Migration::Bookkeeping.ensure_tables(conn.adapter, conn.db)
        backend.exec(conn,
          "INSERT INTO prostore_migration (source_hash, target_hash, status) VALUES (?, ?, ?)",
          "deadbeef", "feedface", Prostore::Migration::State::MIGRATION_RUNNING)

        expect_raises(Prostore::MigrationError, /in flight/) do
          Prostore::Migration::Internal.run(conn.adapter, conn.db)
        end
      end
    end
  end
end
