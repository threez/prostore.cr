# expect: lazy: is mutually exclusive with default:
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :score, Int32?,
    default: Prostore::SQL.expr("0"),
    lazy: ->(_row : M) { 0 }
end
