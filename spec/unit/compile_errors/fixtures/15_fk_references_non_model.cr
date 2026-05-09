# expect: references: must be a Prostore::Model subclass
require "../../../../src/prostore"

class NotAModel
end

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :other_id, Int64

  foreign_key 1, [:other_id], references: NotAModel
end
