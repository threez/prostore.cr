require "../spec_helper"

# Pure unit coverage for the four built-in enum naming algorithms
# (ADR-0017). The conversions are deliberately conservative — verify
# both the documented happy paths and the boundary cases that motivated
# the specific regex pair (consecutive uppercase, digits, single-word
# members).

describe Prostore::Schema::NameConversion do
  describe ":as_declared" do
    it "returns the input verbatim" do
      Prostore::Schema::NameConversion.apply("BounceHard", :as_declared).should eq("BounceHard")
      Prostore::Schema::NameConversion.apply("Active", :as_declared).should eq("Active")
    end
  end

  describe ":snake_case" do
    it "splits PascalCase boundaries" do
      Prostore::Schema::NameConversion.apply("BounceHard", :snake_case).should eq("bounce_hard")
      Prostore::Schema::NameConversion.apply("ComplaintAbuse", :snake_case).should eq("complaint_abuse")
    end

    it "lowercases single-word members" do
      Prostore::Schema::NameConversion.apply("Active", :snake_case).should eq("active")
    end

    it "keeps acronyms grouped (matches Crystal's String#underscore)" do
      Prostore::Schema::NameConversion.apply("HTTPError", :snake_case).should eq("http_error")
      Prostore::Schema::NameConversion.apply("XMLParser", :snake_case).should eq("xml_parser")
    end

    it "handles members with digits" do
      Prostore::Schema::NameConversion.apply("Code404", :snake_case).should eq("code404")
      Prostore::Schema::NameConversion.apply("V2Endpoint", :snake_case).should eq("v2_endpoint")
    end
  end

  describe ":kebab_case" do
    it "splits with hyphens" do
      Prostore::Schema::NameConversion.apply("BounceHard", :kebab_case).should eq("bounce-hard")
      Prostore::Schema::NameConversion.apply("Active", :kebab_case).should eq("active")
    end
  end

  describe ":lower_case" do
    it "downcases without separating words" do
      Prostore::Schema::NameConversion.apply("BounceHard", :lower_case).should eq("bouncehard")
      Prostore::Schema::NameConversion.apply("Active", :lower_case).should eq("active")
    end
  end

  it "raises on unknown algorithms" do
    expect_raises(ArgumentError, /unknown enum naming algorithm/) do
      Prostore::Schema::NameConversion.apply("X", :screaming_snake)
    end
  end
end
