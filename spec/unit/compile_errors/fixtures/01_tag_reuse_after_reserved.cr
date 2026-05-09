# expect: was reserved
require "../../../../src/prostore"

class M < Prostore::Model
  reserved 1
  field 1, :name, String
end
