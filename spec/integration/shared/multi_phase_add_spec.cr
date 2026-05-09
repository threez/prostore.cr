require "./spec_helper"

# Multi-phase AddField with backfill ≠ default. Works on both backends —
# SQLite via table-rebuild, Postgres via native ALTER COLUMN.

private class SMpBefore < Prostore::Model
  table_name "s_mp"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :legacy_email, String

  index 1, [:legacy_email], unique: true
end

private class SMpAfter < Prostore::Model
  table_name "s_mp"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :legacy_email, String
  field 3, :email, String,
    default: Prostore::SQL.expr("'unknown@example.com'"),
    backfill: Prostore::SQL.expr("legacy_email")

  index 1, [:legacy_email], unique: true
end

private class SMpAfterLambda < Prostore::Model
  table_name "s_mp"

  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :legacy_email, String
  field 3, :score, Int32,
    default: Prostore::SQL.expr("0"),
    backfill: ->(_row : SMpAfterLambda) { 42 }

  index 1, [:legacy_email], unique: true
end

BACKENDS.each do |backend|
  describe "#{backend.name}: multi-phase AddField" do
    it "adds a non-null column with backfill from another column, then applies NOT NULL" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SMpBefore] of Prostore::Model.class)
        backend.exec(conn, "INSERT INTO s_mp (legacy_email) VALUES (?)", "alice@old.test")
        backend.exec(conn, "INSERT INTO s_mp (legacy_email) VALUES (?)", "bob@old.test")

        Prostore::Migration::Runner.migrate(conn, [SMpAfter] of Prostore::Model.class)

        values = [] of String
        conn.db.query_each("SELECT email FROM s_mp ORDER BY id") { |rs| values << rs.read(String) }
        values.should eq(["alice@old.test", "bob@old.test"])

        # Column is now NOT NULL.
        # SQLite says "NOT NULL", Postgres says "not-null" — match either.
        expect_raises(Exception, /[Nn][Oo][Tt][ -][Nn][Uu][Ll][Ll]/) do
          backend.exec(conn, "INSERT INTO s_mp (legacy_email, email) VALUES (?, NULL)", "x@old.test")
        end

        # New rows use the default.
        backend.exec(conn, "INSERT INTO s_mp (legacy_email) VALUES (?)", "carol@old.test")
        carol = backend.query_one(conn, "SELECT email FROM s_mp WHERE legacy_email = ?", "carol@old.test", as: String)
        carol.should eq("unknown@example.com")
      end
    end

    it "preserves indexes through the schema change" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SMpBefore] of Prostore::Model.class)
        Prostore::Migration::Runner.migrate(conn, [SMpAfter] of Prostore::Model.class)

        idx_names = conn.adapter.introspect_table("s_mp").indexes.map(&.name).sort!
        idx_names.should contain("s_mp_legacy_email_idx")
      end
    end

    it "Crystal-lambda backfill executes the lambda for each row" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SMpBefore] of Prostore::Model.class)
        backend.exec(conn, "INSERT INTO s_mp (legacy_email) VALUES (?)", "alice@old.test")
        backend.exec(conn, "INSERT INTO s_mp (legacy_email) VALUES (?)", "bob@old.test")

        Prostore::Migration::Runner.migrate(conn, [SMpAfterLambda] of Prostore::Model.class)

        scores = [] of Int32
        conn.db.query_each("SELECT score FROM s_mp") { |rs| scores << rs.read(Int32) }
        scores.size.should eq(2)
        scores.all?(&.==(42)).should be_true
      end
    end
  end
end
