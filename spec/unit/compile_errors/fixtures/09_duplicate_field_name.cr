# expect: Duplicate field name
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :name, Int64
end
