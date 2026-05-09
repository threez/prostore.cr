require "./spec_helper"
require "uuid"
require "big"
require "json"

private class SCustomUser < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :external_id, UUID
  field 3, :balance, BigDecimal
  field 4, :metadata, JSON::Any?
  field 5, :tag_ids, Array(Int32)
  field 6, :tag_names, Array(String)
end

BACKENDS.each do |backend|
  describe "#{backend.name}: custom types (ADR-0015)" do
    it "round-trips UUID" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SCustomUser] of Prostore::Model.class)

        uuid = UUID.random
        u = SCustomUser.allocate
        u.external_id = uuid
        u.balance = BigDecimal.new("0")
        u.tag_ids = [1, 2, 3]
        u.tag_names = ["a", "b"]
        u.save

        SCustomUser.find(u.id).external_id.should eq(uuid)
      end
    end

    it "round-trips BigDecimal preserving precision" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SCustomUser] of Prostore::Model.class)

        d = BigDecimal.new("1234567890.0987654321")
        u = SCustomUser.allocate
        u.external_id = UUID.random
        u.balance = d
        u.tag_ids = [] of Int32
        u.tag_names = [] of String
        u.save

        SCustomUser.find(u.id).balance.should eq(d)
      end
    end

    it "round-trips JSON::Any" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SCustomUser] of Prostore::Model.class)

        payload = JSON.parse(%({"plan": "pro", "limits": {"requests": 1000}}))
        u = SCustomUser.allocate
        u.external_id = UUID.random
        u.balance = BigDecimal.new("0")
        u.metadata = payload
        u.tag_ids = [] of Int32
        u.tag_names = [] of String
        u.save

        reloaded = SCustomUser.find(u.id)
        reloaded.metadata.not_nil!["plan"].as_s.should eq("pro")
        reloaded.metadata.not_nil!["limits"]["requests"].as_i.should eq(1000)
      end
    end

    it "round-trips Array(Int32) and Array(String)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SCustomUser] of Prostore::Model.class)

        u = SCustomUser.allocate
        u.external_id = UUID.random
        u.balance = BigDecimal.new("0")
        u.tag_ids = [10, 20, 30]
        u.tag_names = ["alpha", "beta"]
        u.save

        reloaded = SCustomUser.find(u.id)
        reloaded.tag_ids.should eq([10, 20, 30])
        reloaded.tag_names.should eq(["alpha", "beta"])
      end
    end
  end
end
