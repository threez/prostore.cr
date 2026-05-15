# expect: auto_increment is not supported on enum fields
require "../../../../src/prostore"

enum Role
  Admin
  Member
end

class M < Prostore::Model
  field 1, :role, Role, primary: true, auto_increment: true
end
