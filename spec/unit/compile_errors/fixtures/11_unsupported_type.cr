# expect: not in the portable type set
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :tags, Hash(String, Int32)
end
