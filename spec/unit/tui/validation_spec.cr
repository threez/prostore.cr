require "../../spec_helper"
require "../../../src/prostore/tui/validation"

# Numeric validators are pure functions; cover the obvious happy path,
# whitespace tolerance, negative/positive signs, scientific notation
# (floats only), and the failure modes the TUI surfaces as red errors.

describe Prostore::TUI::Validation do
  describe ".valid_int?" do
    it "accepts plain and signed integers" do
      Prostore::TUI::Validation.valid_int?("0").should be_true
      Prostore::TUI::Validation.valid_int?("42").should be_true
      Prostore::TUI::Validation.valid_int?("-17").should be_true
      Prostore::TUI::Validation.valid_int?("+5").should be_true
    end

    it "tolerates surrounding whitespace" do
      Prostore::TUI::Validation.valid_int?("  42  ").should be_true
    end

    it "rejects floats, hex, and arbitrary text" do
      Prostore::TUI::Validation.valid_int?("1.5").should be_false
      Prostore::TUI::Validation.valid_int?("0x10").should be_false
      Prostore::TUI::Validation.valid_int?("abc").should be_false
      Prostore::TUI::Validation.valid_int?("").should be_false
    end
  end

  describe ".valid_float?" do
    it "accepts plain, signed, and scientific notation" do
      Prostore::TUI::Validation.valid_float?("3.14").should be_true
      Prostore::TUI::Validation.valid_float?("-2.5").should be_true
      Prostore::TUI::Validation.valid_float?("1e9").should be_true
      Prostore::TUI::Validation.valid_float?("0").should be_true
    end

    it "tolerates surrounding whitespace" do
      Prostore::TUI::Validation.valid_float?("  -1.5  ").should be_true
    end

    it "rejects non-numeric text" do
      Prostore::TUI::Validation.valid_float?("foo").should be_false
      Prostore::TUI::Validation.valid_float?("").should be_false
      Prostore::TUI::Validation.valid_float?("1.2.3").should be_false
    end
  end

  describe ".valid_decimal?" do
    it "accepts integer and decimal strings" do
      Prostore::TUI::Validation.valid_decimal?("0").should be_true
      Prostore::TUI::Validation.valid_decimal?("3.14159").should be_true
      Prostore::TUI::Validation.valid_decimal?("-100.001").should be_true
    end

    it "tolerates surrounding whitespace" do
      Prostore::TUI::Validation.valid_decimal?("  42.0  ").should be_true
    end

    it "rejects non-numeric text" do
      Prostore::TUI::Validation.valid_decimal?("foo").should be_false
      Prostore::TUI::Validation.valid_decimal?("").should be_false
    end
  end
end
