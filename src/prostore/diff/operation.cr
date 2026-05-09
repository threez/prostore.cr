require "../schema"

module Prostore
  module Diff
    # Operations are the user-level units the diff engine emits.
    #
    # An Operation describes *what* changed at the schema level — adding a
    # column, dropping an index, renaming a foreign key. Each operation is
    # then lowered to one or more atomic Steps by `Steps::Planner`. The
    # diff engine produces operations; the planner produces the executable
    # step list.
    #
    # Operations are pure data — no DB references, no SQL strings. This
    # keeps the engine easily testable as a function and aligns with
    # ADR-0009's plan-at-start invariant (the operation list is the
    # authoritative target before any DDL runs).
    module Operation
      record CreateTable, definition : Schema::Definition
      record DropTable, table_name : String

      record AddField, table_name : String, field : Schema::Field
      record DropField, table_name : String, tag : Int32, current_name : String
      record RenameField, table_name : String, tag : Int32, from_name : String, to_name : String

      record AddIndex, table_name : String, index : Schema::Index
      record DropIndex, table_name : String, tag : Int32, current_name : String
      record RenameIndex, table_name : String, tag : Int32, from_name : String, to_name : String

      record AddForeignKey, table_name : String, foreign_key : Schema::ForeignKey
      record DropForeignKey, table_name : String, tag : Int32, current_name : String

      alias Any = CreateTable | DropTable |
                  AddField | DropField | RenameField |
                  AddIndex | DropIndex | RenameIndex |
                  AddForeignKey | DropForeignKey
    end
  end
end
