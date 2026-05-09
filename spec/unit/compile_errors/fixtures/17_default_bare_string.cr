# expect: default: does not accept a bare String literal
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :created_at, Time, default: "CURRENT_TIMESTAMP"
end
