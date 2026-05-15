require "./spec_helper"
require "../../../src/prostore/tui/browser"

# Coverage for Browser#enum_columns — the TUI's window onto enum metadata
# stored in the prostore_schema bookkeeping table (ADR-0016).
#
# The TUI editor needs (a) the list of declared members so it can render a
# picker, and (b) the is_flags flag so it picks the radio (single-select)
# vs checkbox (multi-select) variant. Both come from the typed columns
# populated by the migration runner — exercise the full round-trip here so
# changes to either side notice mismatches.

enum TBEStatus
  Active
  Pending
  Archived
end

enum TBETier
  Bronze
  Silver =  5
  Gold   = 10
end

@[Flags]
enum TBEPerms
  Read
  Write
  Execute
end

private class TBEUser < Prostore::Model
  table_name "tbe_user"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :status, TBEStatus       # enum_string
  field 4, :tier, TBETier, as: :int # enum_int
  field 5, :perms, TBEPerms         # enum_int + flags
end

BACKENDS.each do |backend|
  describe "#{backend.name}: TUI Browser enum_columns" do
    it "returns members and flags flag for every enum column" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [TBEUser] of Prostore::Model.class)

        browser = Prostore::TUI::Browser.new(conn)
        meta = browser.enum_columns("tbe_user")

        meta.keys.sort!.should eq(%w[perms status tier])

        status = meta["status"]
        status.is_flags.should be_false
        status.members.map(&.name).should eq(%w[Active Pending Archived])
        status.members.map(&.value).should eq([0_i64, 1_i64, 2_i64])

        tier = meta["tier"]
        tier.is_flags.should be_false
        tier.members.map(&.name).should eq(%w[Bronze Silver Gold])
        tier.members.map(&.value).should eq([0_i64, 5_i64, 10_i64])

        perms = meta["perms"]
        perms.is_flags.should be_true
        perms.members.map(&.name).should eq(%w[Read Write Execute])
        perms.members.map(&.value).should eq([1_i64, 2_i64, 4_i64])
      end
    end

    it "omits non-enum columns and returns empty for unmanaged tables" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [TBEUser] of Prostore::Model.class)
        browser = Prostore::TUI::Browser.new(conn)

        # Non-enum columns (id, name) must not appear in the result.
        meta = browser.enum_columns("tbe_user")
        meta.has_key?("id").should be_false
        meta.has_key?("name").should be_false

        # Unknown / unmanaged tables return an empty hash, not an error —
        # the TUI is meant to gracefully degrade against foreign databases.
        browser.enum_columns("nope_does_not_exist").should be_empty
      end
    end
  end
end
