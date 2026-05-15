require "digest/sha256"

module Prostore
  module Schema
    # A stable hash over a model's `Definition` (ADR-0009 invariant 4).
    #
    # The fingerprint identifies a *target schema state*, not a *labeling*.
    # Names are excluded from the hash so a rename does not change the
    # fingerprint — renames are pure label changes per ADR-0002. Fields,
    # indexes, and FKs are sorted by tag so declaration order doesn't affect
    # the result.
    #
    # The fingerprint is the basis for ADR-0009's version-skew check: an app
    # booting against an in-progress migration must compute the same target
    # hash as the migration was started with, or it refuses to start.
    module Fingerprint
      def self.compute(definition : Definition) : String
        io = IO::Memory.new
        io << "prostore-fingerprint\n"
        io << "table:" << definition.table_name << '\n'

        definition.fields.sort_by(&.tag).each do |field|
          io << "field:" << field.tag
          io << ':' << field.portable_type
          io << ':' << (field.nullable ? "null" : "notnull")
          io << ':' << (field.primary ? "pk" : "_")
          io << ':' << (field.auto_increment ? "autoinc" : "_")
          io << ':' << (field.has_default ? "default" : "_")
          io << ':' << (field.default_sql || "_")
          io << ':' << (field.has_backfill ? "backfill" : "_")
          io << ':' << (field.backfill_sql || "_")
          io << ':' << (field.has_lazy ? "lazy" : "_")
          io << ':' << (field.enum_is_flags ? "flags" : "_")
          io << ':' << (
            if members = field.enum_members
              # `wire_name` is part of the schema contract (ADR-0017): a
              # member rename or naming-algorithm change must be visible
              # to the drift detector and the version-skew check, even
              # when the source-level name stays the same.
              members.map { |member| "#{member.name}=#{member.value}=#{member.wire_name}" }.join(',')
            else
              "_"
            end
          )
          io << '\n'
        end

        definition.reserved_field_tags.sort.each do |tag|
          io << "reserved_field:" << tag << '\n'
        end

        definition.indexes.sort_by(&.tag).each do |idx|
          io << "index:" << idx.tag
          io << ':' << (idx.unique ? "unique" : "_")
          io << ':' << (idx.where_sql || "_")
          idx.columns.each { |col| io << ':' << col }
          io << '\n'
        end

        definition.reserved_index_tags.sort.each do |tag|
          io << "reserved_index:" << tag << '\n'
        end

        definition.foreign_keys.sort_by(&.tag).each do |fk|
          io << "fk:" << fk.tag
          io << ':' << fk.references_table
          io << ':' << fk.on_delete
          io << ':' << fk.on_update
          fk.columns.each { |col| io << ':' << col }
          io << ":->"
          fk.references_columns.each { |col| io << ':' << col }
          io << '\n'
        end

        definition.reserved_foreign_key_tags.sort.each do |tag|
          io << "reserved_fk:" << tag << '\n'
        end

        Digest::SHA256.hexdigest(io.to_s)
      end
    end
  end
end
