# expect: auto_increment requires Int32 or Int64
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, String, primary: true, auto_increment: true
end
