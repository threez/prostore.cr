# expect: starts with reserved 'prostore_' prefix
require "../../../../src/prostore"

class M < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :prostore_secret, String
end
