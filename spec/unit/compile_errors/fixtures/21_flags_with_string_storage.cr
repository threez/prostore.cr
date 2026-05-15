# expect: must be int-backed
require "../../../../src/prostore"

@[Flags]
enum Perms
  Read
  Write
end

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :perms, Perms, as: :string
end
