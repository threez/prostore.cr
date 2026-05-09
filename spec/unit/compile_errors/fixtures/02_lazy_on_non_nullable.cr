# expect: lazy: requires the field type to be T?
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :score, Int32, lazy: ->(_row : M) { 0 }
end
