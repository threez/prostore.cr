# expect: ADR-0008 interlock
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  reserved 2

  # Index references reserved tag's name (which doesn't exist as an active field).
  index 1, [:legacy_email]
end
