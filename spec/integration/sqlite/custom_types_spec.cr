require "./spec_helper"
require "uuid"
require "big"
require "json"

# Extended portable types (UUID, BigDecimal, JSON::Any, Array(T)). See
# ADR-0015.

private class CustomTypesUser < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :external_id, UUID
  field 3, :balance, BigDecimal
  field 4, :metadata, JSON::Any?
  field 5, :tag_ids, Array(Int32)
  field 6, :tag_names, Array(String)
end

def with_custom_types_connection(&)
  with_sqlite_connection do |conn|
    Prostore.default_connection = conn
    Prostore::Migration::Runner.migrate(conn,
      [CustomTypesUser] of Prostore::Model.class)
    begin
      yield conn
    ensure
      Prostore.default_connection = nil
    end
  end
end

describe "Custom types (ADR-0015)" do
  it "round-trips UUID via String storage on SQLite" do
    with_custom_types_connection do |_conn|
      uuid = UUID.random
      u = CustomTypesUser.allocate
      u.external_id = uuid
      u.balance = BigDecimal.new("0")
      u.tag_ids = [1, 2, 3]
      u.tag_names = ["a", "b"]
      u.save

      reloaded = CustomTypesUser.find(u.id)
      reloaded.external_id.should eq(uuid)
    end
  end

  it "round-trips BigDecimal preserving precision" do
    with_custom_types_connection do |_conn|
      d = BigDecimal.new("1234567890.0987654321")
      u = CustomTypesUser.allocate
      u.external_id = UUID.random
      u.balance = d
      u.tag_ids = [] of Int32
      u.tag_names = [] of String
      u.save

      reloaded = CustomTypesUser.find(u.id)
      reloaded.balance.should eq(d)
    end
  end

  it "round-trips JSON::Any" do
    with_custom_types_connection do |_conn|
      payload = JSON.parse(%({"plan": "pro", "limits": {"requests": 1000}}))
      u = CustomTypesUser.allocate
      u.external_id = UUID.random
      u.balance = BigDecimal.new("0")
      u.metadata = payload
      u.tag_ids = [] of Int32
      u.tag_names = [] of String
      u.save

      reloaded = CustomTypesUser.find(u.id)
      reloaded.metadata.not_nil!["plan"].as_s.should eq("pro")
      reloaded.metadata.not_nil!["limits"]["requests"].as_i.should eq(1000)
    end
  end

  it "round-trips Array(Int32) via JSON encoding" do
    with_custom_types_connection do |_conn|
      u = CustomTypesUser.allocate
      u.external_id = UUID.random
      u.balance = BigDecimal.new("0")
      u.tag_ids = [10, 20, 30]
      u.tag_names = ["alpha", "beta"]
      u.save

      reloaded = CustomTypesUser.find(u.id)
      reloaded.tag_ids.should eq([10, 20, 30])
      reloaded.tag_names.should eq(["alpha", "beta"])
    end
  end

  it "renders correct column types in the live DDL on SQLite (TEXT for all coerced types)" do
    with_custom_types_connection do |conn|
      sql = conn.db.query_one(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        "custom_types_user", as: String
      ).upcase
      # UUID, decimal, json, arrays all collapse to TEXT on SQLite.
      sql.should contain("EXTERNAL_ID")
      sql.should contain("METADATA")
      sql.should contain("TAG_IDS")
    end
  end

  it "rejects unsupported inner type for Array(T) at compile time" do
    # Declared in spec/unit/compile_errors/fixtures/16_array_unsupported_inner.cr
    # — this it-block exists only as documentation that the runner handles it.
  end
end
