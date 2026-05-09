# expect: uses :set_default but source field
require "../../../../src/prostore"

class Tenant < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
end

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :tenant_id, Int64

  foreign_key 1, [:tenant_id], references: Tenant, on_delete: :set_default
end
