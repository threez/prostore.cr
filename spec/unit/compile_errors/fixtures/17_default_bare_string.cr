# expect: default: accepts SQL.expr(...), a Crystal lambda, or a scalar literal
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :created_at, Time, default: :current_timestamp
end
