# expect: backfill: accepts SQL.expr(...), a Crystal lambda, a scalar literal
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :status, String, backfill: {some: "hash"}
end
