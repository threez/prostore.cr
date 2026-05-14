#!/usr/bin/env crystal
#
# Operator CLI for prostore. Usage:
#
#   prostore migrate status
#   prostore migrate abort <id>
#   prostore drift check
#   prostore backup <destination>
#   prostore browse
#
# Requires DATABASE_URL environment variable. The hosting application must
# require the model classes before invoking this script — typically via a
# `require "./src/your_app"` entry that this script imports.

require "./prostore"
require "./prostore/tui/app"

USAGE = <<-USAGE
Usage:
  prostore migrate status        Show migration history and outstanding drift
  prostore migrate abort <id>    Mark an in-progress migration as aborted
  prostore drift check           Dry-run drift detection
  prostore backup <destination>  Write a backup to <destination>
                                 Supports strftime tokens: %Y %m %d %H %M %S
  prostore browse                Launch interactive TUI database browser
USAGE

def die(msg : String) : NoReturn
  STDERR.puts msg
  exit 1
end

url = ENV["DATABASE_URL"]? || die("DATABASE_URL is not set")
conn = Prostore::Connection.open(url)

begin
  case ARGV[0]?
  when "migrate"
    case ARGV[1]?
    when "status"
      Prostore::Migration::CLI.status(conn)
    when "abort"
      id = ARGV[2]?.try(&.to_i64?) || die("expected integer migration id")
      Prostore::Migration::CLI.abort(conn, id)
    else
      die(USAGE)
    end
  when "drift"
    case ARGV[1]?
    when "check"
      Prostore::Migration::CLI.drift_check(conn)
    else
      die(USAGE)
    end
  when "backup"
    dest = ARGV[1]? || die(USAGE)
    path = Prostore::Backup.run(conn, dest)
    STDOUT.puts "Backup written to #{path}"
  when "browse"
    Prostore::TUI::App.run(conn)
  else
    die(USAGE)
  end
ensure
  conn.close
end
