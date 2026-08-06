#!/usr/bin/env crystal
# Seeds examples/bookstore/bookstore.sqlite3, migrated through prostore's own
# migration runner (so the prostore_schema bookkeeping table exists), with
# columns that exercise every RecordDetail editor kind: bool, enum_string,
# enum_int, @[Flags], a single-column FK, and free text.
#
# Usage:
#   crystal run examples/bookstore/seed.cr
#   DATABASE_URL=sqlite3://examples/bookstore/bookstore.sqlite3 bin/prostore browse
#
# Or just `make example-bookstore`, which does both.

require "../../src/prostore"

enum BookStatus
  Draft
  Published
  Archived
end

enum BookTier
  Bronze
  Silver =  5
  Gold   = 10
end

@[Flags]
enum BookPerms
  Read  =  1
  Write =  2
  Admin =  8
  Owner = 32
end

class Author < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :name, String
  field 3, :bio, String?
end

class Book < Prostore::Model
  field 1, :id, Int64, primary: true, auto_increment: true
  field 2, :title, String
  field 3, :active, Bool
  field 4, :status, BookStatus       # enum_string
  field 5, :tier, BookTier, as: :int # enum_int
  field 6, :perms, BookPerms         # enum_int + flags, non-contiguous values
  field 7, :pages, Int32?
  field 8, :notes, String?

  foreign_key 1, [:author_id], references: Author
  field 9, :author_id, Int64?
end

path = ARGV[0]? || File.join(__DIR__, "bookstore.sqlite3")
File.delete(path) if File.exists?(path)

conn = Prostore.connect("sqlite3://#{path}")
begin
  Prostore::Migration::Runner.migrate(conn, [Author, Book] of Prostore::Model.class)

  ada = Author.allocate
  ada.name = "Ada Lovelace"
  ada.bio = "Mathematician and writer, wrote the first published algorithm."
  ada.save

  alan = Author.allocate
  alan.name = "Alan Turing"
  alan.bio = nil
  alan.save

  notes = Book.allocate
  notes.title = "Notes on the Analytical Engine"
  notes.active = true
  notes.status = BookStatus::Published
  notes.tier = BookTier::Gold
  notes.perms = BookPerms::Read | BookPerms::Write | BookPerms::Owner # = 35, non-contiguous
  notes.pages = 120
  notes.notes = "A long note that should soft-wrap across several display rows " \
                "once it exceeds the value column width, so you can see the " \
                "wrap-continuation marker in both display and edit mode."
  notes.author_id = ada.id
  notes.save

  computable = Book.allocate
  computable.title = "On Computable Numbers"
  computable.active = false
  computable.status = BookStatus::Draft
  computable.tier = BookTier::Bronze
  computable.perms = BookPerms::None
  computable.pages = nil
  computable.notes = nil
  computable.author_id = alan.id
  computable.save

  puts "Seeded #{path}"
ensure
  conn.close
end
