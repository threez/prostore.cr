require "../../spec_helper"

# Compile-error fixture runner.
#
# Each fixture file in `fixtures/` declares an intentional misuse of the
# prostore DSL that must fail to compile. The first line of each fixture is
# `# expect: <substring>` — the runner verifies that the compile error
# contains that substring.

FIXTURE_DIR = File.expand_path("fixtures", __DIR__)

private def compile_only(path : String) : {Int32, String}
  output = IO::Memory.new
  status = Process.run(
    "crystal",
    {"build", "--no-codegen", path},
    output: output,
    error: output,
  )
  {status.exit_code, output.to_s}
end

private def expected_substring(path : String) : String
  first_line = File.open(path, &.gets) || ""
  prefix = "# expect:"
  unless first_line.starts_with?(prefix)
    raise "fixture #{path} is missing a `# expect: ...` first line"
  end
  first_line[prefix.size..].strip
end

describe "compile-error fixtures" do
  Dir.children(FIXTURE_DIR).sort.each do |entry|
    next unless entry.ends_with?(".cr")
    path = File.join(FIXTURE_DIR, entry)

    it "rejects #{entry}" do
      expected = expected_substring(path)
      exit_code, output = compile_only(path)
      exit_code.should_not eq(0), "expected #{entry} to fail compilation but it succeeded\n#{output}"
      output.should contain(expected), "expected error output to contain #{expected.inspect}\nactual output:\n#{output}"
    end
  end
end
