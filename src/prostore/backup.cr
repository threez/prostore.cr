require "./connection"

module Prostore
  # Point-in-time backup for SQLite and PostgreSQL databases.
  #
  # `run` accepts a destination path that may contain strftime tokens
  # (`%Y %m %d %H %M %S`). Tokens are expanded to the current UTC time
  # before the backup is written, so a single cron line produces
  # naturally-rotated, timestamped files.
  #
  # See the README "Backup" section for cron examples.
  module Backup
    extend self

    # Write a backup to `dest` and return the final path used.
    # `dest` may contain strftime tokens; expansion uses UTC time.
    def run(conn : Connection, dest : String) : String
      path = Time.utc.to_s(dest)
      conn.adapter.backup(path)
      path
    end
  end
end
