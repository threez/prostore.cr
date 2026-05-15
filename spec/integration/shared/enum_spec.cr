require "./spec_helper"

# Integration coverage for ADR-0016 native enums:
# - end-to-end save/read for string-backed, int-backed, and flags enums
# - migration scenario: add a member, verify CHECK widens and existing rows survive
# - negative: removing a member raises with the ADR-0016 guidance
# - CHECK enforces the declared value set at the storage layer

enum IEnumStatus
  Active
  Pending
  Archived
end

enum IEnumStatusPlus
  Active
  Pending
  Archived
  Banned
end

enum IEnumStatusReduced
  Active
  Pending
end

enum IEnumTier
  Bronze
  Silver =  5
  Gold   = 10
end

@[Flags]
enum IEnumPerms
  Read
  Write
  Execute
end

private class IEnumUser < Prostore::Model
  table_name "ienum_user"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :status, IEnumStatus
  field 4, :tier, IEnumTier, as: :int
  field 5, :perms, IEnumPerms
end

private class IEnumUserExtended < Prostore::Model
  table_name "ienum_user"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :status, IEnumStatusPlus
  field 4, :tier, IEnumTier, as: :int
  field 5, :perms, IEnumPerms
end

private class IEnumUserReduced < Prostore::Model
  table_name "ienum_user"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :status, IEnumStatusReduced
  field 4, :tier, IEnumTier, as: :int
  field 5, :perms, IEnumPerms
end

BACKENDS.each do |backend|
  describe "#{backend.name}: native enum CRUD (ADR-0016)" do
    it "round-trips string-backed, int-backed, and flags enum columns" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [IEnumUser] of Prostore::Model.class)

        u = IEnumUser.allocate
        u.name = "alice"
        u.status = IEnumStatus::Pending
        u.tier = IEnumTier::Silver
        u.perms = IEnumPerms::Read | IEnumPerms::Write
        u.save

        reloaded = IEnumUser.find(u.id)
        reloaded.status.should eq(IEnumStatus::Pending)
        reloaded.tier.should eq(IEnumTier::Silver)
        reloaded.perms.should eq(IEnumPerms::Read | IEnumPerms::Write)

        # Confirm raw storage form: string column stores the name, int the value.
        stored_status = backend.query_one(conn,
          "SELECT status FROM ienum_user WHERE id = ?", u.id, as: String)
        stored_status.should eq("Pending")

        stored_tier = backend.query_one(conn,
          "SELECT tier FROM ienum_user WHERE id = ?", u.id, as: Int64)
        stored_tier.should eq(5_i64)
      end
    end

    it "CHECK constraint rejects values outside the declared set" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [IEnumUser] of Prostore::Model.class)

        u = IEnumUser.allocate
        u.name = "violator"
        u.status = IEnumStatus::Active
        u.tier = IEnumTier::Bronze
        u.perms = IEnumPerms::None
        u.save

        expect_raises(Exception) do
          backend.exec(conn,
            "UPDATE ienum_user SET status = ? WHERE id = ?",
            "BogusValue", u.id)
        end
      end
    end

    it "widens an enum column when a member is added (additive migration)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [IEnumUser] of Prostore::Model.class)

        u = IEnumUser.allocate
        u.name = "founder"
        u.status = IEnumStatus::Active
        u.tier = IEnumTier::Bronze
        u.perms = IEnumPerms::Read
        u.save
        founder_id = u.id

        # Now widen: same column, one new member.
        Prostore::Migration::Runner.migrate(conn, [IEnumUserExtended] of Prostore::Model.class)

        # Existing row survived the rebuild / CHECK swap.
        again = IEnumUser.find(founder_id)
        again.status.should eq(IEnumStatus::Active)
        again.name.should eq("founder")

        # New rows can use the newly-added member.
        backend.exec(conn,
          "INSERT INTO ienum_user (name, status, tier, perms) VALUES (?, ?, ?, ?)",
          "outcast", "Banned", 0_i64, 0_i64)

        count = backend.query_one(conn,
          "SELECT COUNT(*) FROM ienum_user WHERE status = ?", "Banned",
          as: Int64)
        count.should eq(1_i64)
      end
    end

    it "rejects removing an enum member with the ADR-0016 guidance" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [IEnumUser] of Prostore::Model.class)

        expect_raises(Prostore::SchemaError, /enum member.*Archived.*removed/) do
          Prostore::Migration::Runner.migrate(conn, [IEnumUserReduced] of Prostore::Model.class)
        end
      end
    end
  end
end
