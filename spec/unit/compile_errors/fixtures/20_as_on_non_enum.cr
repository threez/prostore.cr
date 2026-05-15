# expect: `as:` is only valid for Enum field types
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String, as: :int
end
