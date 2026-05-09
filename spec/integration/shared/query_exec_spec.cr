require "./spec_helper"

private class QSUser < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :tenant_id, Int64
  field 4, :score, Int32
  field 5, :status, String

  index 1, [:email], unique: true
  index 2, [:tenant_id]
  index 3, [:score]
  index 4, [:status]

  query :by_email, ->(e : String) { where(email: e) }
  query :recent_in_tenant, ->(t : Int64) { where(tenant_id: t).order_by(:id, desc: true).limit(10) }
end

private class QSOrder < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :user_id, Int64
  field 3, :total, Int64

  index 1, [:user_id]

  foreign_key 1, [:user_id], references: QSUser
end

private class QSTag < Prostore::Model
  field 1, :id, String, primary: true
  field 2, :label, String
end

private def insert_qs_user(backend, conn, email, tenant_id, score, status = "active")
  backend.exec(conn,
    "INSERT INTO qs_user (email, tenant_id, score, status) VALUES (?, ?, ?, ?)",
    email, tenant_id, score, status,
  )
end

BACKENDS.each do |backend|
  describe "#{backend.name}: query execution" do
    it "named query with eq filter returns the matching instance" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)
        insert_qs_user(backend, conn, "alice@x.test", 1_i64, 10)
        insert_qs_user(backend, conn, "bob@x.test", 1_i64, 20)

        results = QSUser.by_email("alice@x.test").to_a
        results.size.should eq(1)
        results.first.email.should eq("alice@x.test")
        results.first.score.should eq(10)
      end
    end

    it "named query with order_by + limit returns the right page" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)
        insert_qs_user(backend, conn, "a@x.test", 1_i64, 1)
        insert_qs_user(backend, conn, "b@x.test", 1_i64, 2)
        insert_qs_user(backend, conn, "c@x.test", 1_i64, 3)
        insert_qs_user(backend, conn, "d@x.test", 2_i64, 4)

        results = QSUser.recent_in_tenant(1_i64).to_a
        results.size.should eq(3)
        results.map(&.email).should eq(["c@x.test", "b@x.test", "a@x.test"])
      end
    end

    it "ad-hoc User.where chains correctly" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)
        insert_qs_user(backend, conn, "a@x.test", 1_i64, 10)
        insert_qs_user(backend, conn, "b@x.test", 2_i64, 20)
        insert_qs_user(backend, conn, "c@x.test", 1_i64, 30)

        out = QSUser.where(tenant_id: 1_i64).order_by(:score).to_a
        out.map(&.email).should eq(["a@x.test", "c@x.test"])
      end
    end

    it "User.find returns instance by primary key" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)
        backend.exec(conn,
          "INSERT INTO qs_user (id, email, tenant_id, score, status) VALUES (?, ?, ?, ?, ?)",
          42_i64, "x@x.test", 1_i64, 10, "active")

        u = QSUser.find(42_i64)
        u.email.should eq("x@x.test")
      end
    end

    it "Range, IN, comparisons, OR, AND, NOT" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)
        insert_qs_user(backend, conn, "a@x.test", 1_i64, 5, "active")
        insert_qs_user(backend, conn, "b@x.test", 1_i64, 50, "pending")
        insert_qs_user(backend, conn, "c@x.test", 1_i64, 500, "deleted")

        QSUser.where(score: 10..100).to_a.map(&.email).should eq(["b@x.test"])
        QSUser.where(score: 1...100).to_a.map(&.email).sort!.should eq(["a@x.test", "b@x.test"])
        QSUser.where(status: ["active", "pending"]).order_by(:score).to_a.map(&.email).should eq(["a@x.test", "b@x.test"])
        QSUser.where(Prostore::Q.gt(:score, 10)).order_by(:score).to_a.map(&.email).should eq(["b@x.test", "c@x.test"])

        # OR
        QSUser.where(
          Prostore::Q.any(Prostore::Q.eq(:status, "active"), Prostore::Q.eq(:status, "pending"))
        ).order_by(:score).to_a.map(&.email).should eq(["a@x.test", "b@x.test"])

        # AND
        QSUser.where(tenant_id: 1_i64).where(Prostore::Q.gt(:score, 10)).order_by(:score).to_a.map(&.email).should eq(["b@x.test", "c@x.test"])

        # NOT
        QSUser.where(Prostore::Q.not(Prostore::Q.eq(:status, "deleted"))).order_by(:score).to_a.map(&.email).should eq(["a@x.test", "b@x.test"])
      end
    end

    it "joins via Model class (auto-resolved FK)" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)
        backend.exec(conn,
          "INSERT INTO qs_user (id, email, tenant_id, score, status) VALUES (?, ?, ?, ?, ?)",
          1_i64, "alice@x.test", 1_i64, 10, "active")
        backend.exec(conn, "INSERT INTO qs_order (user_id, total) VALUES (?, ?)", 1_i64, 250_i64)

        out = QSUser.all.joins(QSOrder).where(Prostore::Q.gt(:total, 100)).to_a
        out.map(&.email).should eq(["alice@x.test"])
      end
    end

    it "select projection limits the columns" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)
        insert_qs_user(backend, conn, "a@x.test", 1_i64, 10)

        u = QSUser.all.select(:id, :email).first.not_nil!
        u.email.should eq("a@x.test")
        expect_raises(Prostore::Error, /not set/) do
          u.score
        end
      end
    end
  end

  describe "#{backend.name}: instance CRUD — String PK" do
    it "save inserts a new record with a user-assigned String PK" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSTag] of Prostore::Model.class)

        t = QSTag.allocate
        t.id = "tag:abc"
        t.label = "first"
        t.save

        QSTag.find("tag:abc").label.should eq("first")
        t.persisted?.should be_true
      end
    end

    it "second save on a String PK record updates, not inserts" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSTag] of Prostore::Model.class)

        t = QSTag.allocate
        t.id = "tag:xyz"
        t.label = "original"
        t.save

        t.label = "updated"
        t.save

        QSTag.find("tag:xyz").label.should eq("updated")
        QSTag.all.count.should eq(1_i64)
      end
    end
  end

  describe "#{backend.name}: instance CRUD" do
    it "save inserts and assigns auto-increment PK" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)

        u = QSUser.allocate
        u.email = "saved@x.test"
        u.tenant_id = 7_i64
        u.score = 99
        u.status = "active"
        u.save

        u.id.should be > 0_i64
        QSUser.find(u.id).email.should eq("saved@x.test")
      end
    end

    it "save updates an existing row" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)

        u = QSUser.allocate
        u.email = "old@x.test"
        u.tenant_id = 1_i64
        u.score = 1
        u.status = "active"
        u.save
        original_id = u.id

        u.email = "new@x.test"
        u.save

        QSUser.find(original_id).email.should eq("new@x.test")
        QSUser.all.count.should eq(1_i64)
      end
    end

    it "destroy removes the row" do
      backend.with_connection do |conn|
        Prostore::Migration::Runner.migrate(conn, [QSUser, QSOrder] of Prostore::Model.class)

        u = QSUser.allocate
        u.email = "doomed@x.test"
        u.tenant_id = 1_i64
        u.score = 1
        u.status = "active"
        u.save
        id = u.id

        u.destroy
        QSUser.find?(id).should be_nil
      end
    end
  end
end
