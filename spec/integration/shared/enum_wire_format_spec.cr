require "./spec_helper"

# Integration coverage for ADR-0017 (per-field enum wire format):
# - end-to-end save/read with snake_case storage
# - CHECK constraint uses wire_name, rejects raw PascalCase
# - backward compat: enums declared without `naming:` continue to store
#   the source-level name (no regression vs. ADR-0016 / v0.3.x)
# - drift: changing `naming:` on an existing column is rejected with the
#   ADR-0017 guidance

enum EWFStatus
  Active
  Pending
  BounceHard
end

enum EWFStatusAsDeclared
  Active
  Pending
  BounceHard
end

private class EWFSnake < Prostore::Model
  table_name "ewf_snake"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :status, EWFStatus, naming: :snake_case
end

private class EWFDefault < Prostore::Model
  table_name "ewf_default"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :status, EWFStatusAsDeclared
end

# Same table name as EWFSnake but with a different naming algorithm —
# used by the drift-rejection test to model a buggy "rename in place"
# attempt without writing a data migration.
private class EWFSnakeFlipped < Prostore::Model
  table_name "ewf_snake"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :status, EWFStatus, naming: :kebab_case
end

BACKENDS.each do |backend|
  describe "#{backend.name}: enum naming (ADR-0017)" do
    it "stores the snake_case wire form and round-trips Crystal enums" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EWFSnake] of Prostore::Model.class)

        u = EWFSnake.allocate
        u.status = EWFStatus::BounceHard
        u.save

        EWFSnake.find(u.id).status.should eq(EWFStatus::BounceHard)

        stored = backend.query_one(conn,
          "SELECT status FROM ewf_snake WHERE id = ?", u.id, as: String)
        stored.should eq("bounce_hard")
      end
    end

    it "writes :as_declared as the wire form for the other two members too" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EWFSnake] of Prostore::Model.class)

        [EWFStatus::Active, EWFStatus::Pending, EWFStatus::BounceHard].each do |member|
          u = EWFSnake.allocate
          u.status = member
          u.save
        end

        rows = [] of String
        backend.query_each(conn, "SELECT status FROM ewf_snake ORDER BY id") do |rs|
          rows << rs.read(String)
        end
        rows.should eq(["active", "pending", "bounce_hard"])
      end
    end

    it "CHECK constraint enforces the snake_case wire form" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EWFSnake] of Prostore::Model.class)

        # Raw INSERT with the old PascalCase form must fail the CHECK.
        expect_raises(Exception) do
          backend.exec(conn,
            "INSERT INTO ewf_snake (status) VALUES (?)", "BounceHard")
        end

        # Raw INSERT with the wire form succeeds, and the ORM reads it back
        # as the right Crystal enum (find via raw lookup since the query
        # builder doesn't yet take Enum values in where predicates).
        backend.exec(conn,
          "INSERT INTO ewf_snake (status) VALUES (?)", "bounce_hard")
        new_id = backend.query_one(conn,
          "SELECT id FROM ewf_snake WHERE status = ?", "bounce_hard", as: Int64)
        EWFSnake.find(new_id).status.should eq(EWFStatus::BounceHard)
      end
    end

    it "backward compat: no `naming:` stores the PascalCase source name" do
      # Regression guard for v0.3.x users — declarations without `naming:`
      # must continue to store member.to_s verbatim.
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EWFDefault] of Prostore::Model.class)

        u = EWFDefault.allocate
        u.status = EWFStatusAsDeclared::BounceHard
        u.save

        stored = backend.query_one(conn,
          "SELECT status FROM ewf_default WHERE id = ?", u.id, as: String)
        stored.should eq("BounceHard")
      end
    end

    it "rejects changing `naming:` on an existing column" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [EWFSnake] of Prostore::Model.class)

        # Same field, same Crystal type, but the naming algorithm changed —
        # existing rows still carry the snake_case wire form, so an
        # in-place flip would corrupt reads.
        expect_raises(Prostore::SchemaError, /wire_name changed/) do
          Prostore::Migration::Runner.migrate(conn, [EWFSnakeFlipped] of Prostore::Model.class)
        end
      end
    end
  end
end
