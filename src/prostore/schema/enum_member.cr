module Prostore
  module Schema
    # A single Crystal enum member captured from a `field` declaration whose
    # type resolves to an `Enum` subclass (ADR-0016). Each member carries its
    # source-level name and the underlying Int64-promoted integer value so the
    # diff engine, fingerprint, and DDL emitters can reason about the allowed
    # value space without re-reading the enum class at runtime.
    record EnumMember,
      name : String,
      value : Int64
  end
end
