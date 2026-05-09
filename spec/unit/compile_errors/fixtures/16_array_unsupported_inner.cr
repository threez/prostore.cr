# expect: inner type must be a portable type
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :tags, Array(Hash(String, Int32))
end
