require "../../spec_helper"

private class QaIndexed < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :email, String
  field 3, :tenant_id, Int64

  index 1, [:email], unique: true
  index 2, [:tenant_id]

  query :by_email, ->(e : String) { where(email: e) }
  query :by_tenant, ->(t : Int64) { where(tenant_id: t) }
end

private class QaMissingIndex < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :status, String

  query :by_status, ->(s : String) { where(status: s) }
end

private class QaLazy < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :score, Int32?, lazy: ->(_row : QaLazy) { 0 }

  index 1, [:score]

  query :by_score, ->(s : Int32) { where(score: s) }
end

# Composite index covers a multi-field where via the leading-prefix rule.
private class QaCompositeOk < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :tenant_id, Int64
  field 3, :status, String

  index 1, [:tenant_id, :status]

  query :scoped, ->(t : Int64, s : String) { where(tenant_id: t, status: s) }
end

# Composite index does NOT cover a where on a non-leading column without
# the leading column also being filtered.
private class QaCompositeMiss < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :tenant_id, Int64
  field 3, :status, String

  index 1, [:tenant_id, :status]

  query :by_status, ->(s : String) { where(status: s) }
end

# Positional `order_by(:score)` form — should be classified as sorted by
# `score` and trigger the strict missing-index check.
private class QaOrderByPositional < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :score, Int32

  query :top, -> { order_by(:score, desc: true) }
end

private class QaOrderByPositionalCovered < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :score, Int32

  index 1, [:score]

  query :top, -> { order_by(:score, desc: true) }
end

# Comparison predicates (Q.lt / Q.gt etc.) in named query bodies.
private class QaPredicateCovered < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :created_at, Time
  field 3, :score, Int32

  index 1, [:created_at]
  index 2, [:score]

  query :before, ->(t : Time) { where(Q.lt(:created_at, t)).order_by(:created_at, desc: true) }
  query :above_score, ->(s : Int32) { where(Q.gt(:score, s)) }
end

private class QaPredicateMissing < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :created_at, Time

  query :before, ->(t : Time) { where(Q.lt(:created_at, t)) }
end

describe Prostore::Query::Analyzer do
  it "classifies fields filtered in named queries" do
    report = Prostore::Query::Analyzer.analyze(QaIndexed.prostore_schema)
    report.all_filtered.should contain("email")
    report.all_filtered.should contain("tenant_id")
  end

  it "passes required-index check when every filtered field has an index" do
    Prostore::Query::Analyzer.validate_indexes!(QaIndexed.prostore_schema)
  end

  it "raises strict missing-index error when filtered field lacks an index" do
    expect_raises(Prostore::SchemaError, /by_status.*status/m) do
      Prostore::Query::Analyzer.validate_indexes!(QaMissingIndex.prostore_schema)
    end
  end

  it "flags lazy fields referenced non-projectionally for override" do
    report = Prostore::Query::Analyzer.analyze(QaLazy.prostore_schema)
    report.lazy_override_fields.should contain("score")
  end

  describe "positional order_by" do
    it "classifies positional symbol args of order_by as sorted fields" do
      report = Prostore::Query::Analyzer.analyze(QaOrderByPositional.prostore_schema)
      report.all_sorted.should contain("score")
    end

    it "raises strict missing-index error for positional order_by without an index" do
      expect_raises(Prostore::SchemaError, /top.*score/m) do
        Prostore::Query::Analyzer.validate_indexes!(QaOrderByPositional.prostore_schema)
      end
    end

    it "passes when an index covers the positional sort field" do
      Prostore::Query::Analyzer.validate_indexes!(QaOrderByPositionalCovered.prostore_schema)
    end
  end

  describe "composite-index covering" do
    it "considers a composite index covering when leading + trailing are both filtered" do
      Prostore::Query::Analyzer.validate_indexes!(QaCompositeOk.prostore_schema)
    end

    it "rejects a query that filters only by a non-leading column of a composite index" do
      expect_raises(Prostore::SchemaError, /by_status.*status/m) do
        Prostore::Query::Analyzer.validate_indexes!(QaCompositeMiss.prostore_schema)
      end
    end
  end

  describe "comparison predicate operators in named queries (Q.lt / Q.gt etc.)" do
    it "classifies field from Q.lt predicate as filtered" do
      report = Prostore::Query::Analyzer.analyze(QaPredicateCovered.prostore_schema)
      report.all_filtered.should contain("created_at")
    end

    it "classifies field from Q.gt predicate as filtered" do
      report = Prostore::Query::Analyzer.analyze(QaPredicateCovered.prostore_schema)
      report.all_filtered.should contain("score")
    end

    it "passes required-index check when predicate field has an index" do
      Prostore::Query::Analyzer.validate_indexes!(QaPredicateCovered.prostore_schema)
    end

    it "raises strict missing-index error when predicate field lacks an index" do
      expect_raises(Prostore::SchemaError, /before.*created_at/m) do
        Prostore::Query::Analyzer.validate_indexes!(QaPredicateMissing.prostore_schema)
      end
    end
  end
end
