# expect: SQL.expr requires a string literal
require "../../../../src/prostore"

EXPR = "now()"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :created_at, Time, default: Prostore::SQL.expr(EXPR), backfill: Prostore::SQL.expr(EXPR)
end
