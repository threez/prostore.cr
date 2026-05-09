# expect: `sequence` is reserved for a future ADR
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true

  sequence 1, :counter
end
