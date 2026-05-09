# expect: starts with reserved 'prostore_' prefix
require "../../../../src/prostore"

class M < Prostore::Model
  table_name "prostore_secret"

  field 1, :id, Int64, primary: true, auto_increment: true
end
