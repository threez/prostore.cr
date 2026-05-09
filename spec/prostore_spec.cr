require "./spec_helper"

describe Prostore do
  it "exposes a version string" do
    Prostore::VERSION.should be_a(String)
  end
end
