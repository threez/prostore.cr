# expect: auto_increment requires primary: true
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :counter, Int64, auto_increment: true
end
