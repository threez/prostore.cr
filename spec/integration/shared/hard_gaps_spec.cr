require "./spec_helper"

private class SHgUser < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :score, Int32, default: ->(_row : SHgUser) { 42 }
end

private class SHgWide < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :a, String
  field 3, :b, String
  field 4, :c, String
end

BACKENDS.each do |backend|
  describe "#{backend.name}: Crystal-lambda default at INSERT" do
    it "evaluates the lambda when the field is unset" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SHgUser] of Prostore::Model.class)

        u = SHgUser.allocate
        u.email = "alice@x.test"
        u.save

        SHgUser.find(u.id).score.should eq(42)
      end
    end

    it "honors an explicit value over the default lambda" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SHgUser] of Prostore::Model.class)

        u = SHgUser.allocate
        u.email = "bob@x.test"
        u.score = 999
        u.save

        SHgUser.find(u.id).score.should eq(999)
      end
    end
  end

  describe "#{backend.name}: select projection" do
    it "limits the SELECT to chosen columns" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SHgWide] of Prostore::Model.class)
        backend.exec(conn, "INSERT INTO s_hg_wide (a, b, c) VALUES (?, ?, ?)", "x", "y", "z")

        result = SHgWide.all.select(:id, :a).first.not_nil!
        result.a.should eq("x")
        expect_raises(Prostore::Error, /not set/) do
          result.b
        end
      end
    end
  end

  describe "#{backend.name}: ResetSequence" do
    it "advances the auto-increment sequence past explicitly-inserted IDs" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [SHgUser] of Prostore::Model.class)

        backend.exec(conn,
          "INSERT INTO s_hg_user (id, email, score) VALUES (?, ?, ?)",
          5000_i64, "a@x.test", 1)

        conn.with_connection do |db_conn|
          Prostore::Steps::Executor.execute(
            conn.adapter, db_conn,
            Prostore::Steps::Kind::ResetSequence.new("s_hg_user", "id"),
          )
        end

        backend.exec(conn, "INSERT INTO s_hg_user (email, score) VALUES (?, ?)", "b@x.test", 2)
        max_id = backend.query_one(conn, "SELECT MAX(id) FROM s_hg_user", as: Int64)
        max_id.should be > 5000_i64
      end
    end
  end
end
