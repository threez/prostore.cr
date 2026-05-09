module Prostore
  class Error < Exception
  end

  class SchemaError < Error
  end

  class MigrationError < Error
  end

  class FingerprintError < MigrationError
  end

  class DriftError < Error
  end
end
