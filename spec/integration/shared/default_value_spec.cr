require "./spec_helper"

# Coverage for the v0.3.1 → 0.4.0 scalar-default fix: declared scalar
# literals (`default: "active"`, `default: 42`, `default: true`) must seed
# the ivar at INSERT time, not just the DDL DEFAULT clause. The macro
# emits every non-PK column in the INSERT column list, so without ORM-side
# seeding the explicit NULL we'd bind from the unset ivar shadows the DB
# default.
#
# Symbol (`:CURRENT_TIMESTAMP`) and `SQL.expr(...)` defaults remain DB-side
# only — they have no Crystal-side value the macro can capture. Users who
# need ORM-side eval for those should wrap them in a lambda.

private class DefaultsLiteralUser < Prostore::Model
  table_name "defaults_literal_user"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :status, String, default: "active", backfill: "active"
  field 4, :count, Int32, default: 7, backfill: 0
  field 5, :active, Bool, default: true, backfill: true
  field 6, :nickname, String?, default: "anon"
end

private class DefaultsLambdaUser < Prostore::Model
  table_name "defaults_lambda_user"
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :slug, String, default: ->(u : DefaultsLambdaUser) { u.name.downcase.gsub(' ', '-') }
end

BACKENDS.each do |backend|
  describe "#{backend.name}: scalar default seeding (.new + .save)" do
    it "seeds a String scalar default on a non-nullable column" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [DefaultsLiteralUser] of Prostore::Model.class)

        u = DefaultsLiteralUser.allocate
        u.name = "alice"
        u.save

        reloaded = DefaultsLiteralUser.find(u.id)
        reloaded.status.should eq("active")
      end
    end

    it "seeds an Int scalar default" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [DefaultsLiteralUser] of Prostore::Model.class)

        u = DefaultsLiteralUser.allocate
        u.name = "alice"
        u.save

        DefaultsLiteralUser.find(u.id).count.should eq(7)
      end
    end

    it "seeds a Bool scalar default" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [DefaultsLiteralUser] of Prostore::Model.class)

        u = DefaultsLiteralUser.allocate
        u.name = "alice"
        u.save

        DefaultsLiteralUser.find(u.id).active.should be_true
      end
    end

    it "seeds a scalar default on a nullable column when the ivar is nil" do
      # Nil on a nullable column is indistinguishable from "unset" — both
      # paths converge on applying the declared default. Matches lambda
      # semantics already documented in ADR-0011 mechanism 2.
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [DefaultsLiteralUser] of Prostore::Model.class)

        u = DefaultsLiteralUser.allocate
        u.name = "alice"
        u.save

        DefaultsLiteralUser.find(u.id).nickname.should eq("anon")
      end
    end

    it "respects an explicitly-set value over the scalar default" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [DefaultsLiteralUser] of Prostore::Model.class)

        u = DefaultsLiteralUser.allocate
        u.name = "alice"
        u.status = "banned"
        u.count = 99
        u.active = false
        u.nickname = "ally"
        u.save

        reloaded = DefaultsLiteralUser.find(u.id)
        reloaded.status.should eq("banned")
        reloaded.count.should eq(99)
        reloaded.active.should be_false
        reloaded.nickname.should eq("ally")
      end
    end

    it "keeps lambda defaults working (regression guard)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [DefaultsLambdaUser] of Prostore::Model.class)

        u = DefaultsLambdaUser.allocate
        u.name = "Alice Smith"
        u.save

        DefaultsLambdaUser.find(u.id).slug.should eq("alice-smith")
      end
    end
  end
end
