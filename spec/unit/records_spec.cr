require "../spec_helper"

# Per-field accessors and lazy materialization on the model class.

private class RecModel < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String?
  field 3, :computed, Int32?, lazy: ->(_row : RecModel) { 42 }
  field 4, :zero_arg_lazy, String?, lazy: -> { "zero-arg" }
  field 5, :zero_arg_default, String?, default: -> { "default-zero" }
end

describe "record API" do
  it "exposes a getter for each field" do
    m = RecModel.allocate
    m.name = "alice"
    m.name.should eq("alice")
  end

  it "materializes a lazy field on first access" do
    m = RecModel.allocate
    m.computed.should eq(42)
  end

  it "materializes lazy fields lazily — already-set value short-circuits the lambda" do
    m = RecModel.allocate
    m.computed = 999
    # Subsequent access returns the explicitly-set value without re-invoking the lambda.
    m.computed.should eq(999)
  end

  it "materializes a 0-arg lazy field on first access" do
    m = RecModel.allocate
    m.zero_arg_lazy.should eq("zero-arg")
  end

  it "0-arg default lambda is recognized at compile time (field declared with default: ->{ ... })" do
    # This verifies the 0-arg ProcLiteral path compiles; runtime behavior is
    # tested via integration specs where save is called against a live DB.
    m = RecModel.allocate
    # The default is only applied at INSERT time (inside save), not at allocate.
    # Just verify the field is accessible and nil before save.
    m.zero_arg_default.should be_nil
  end
end
