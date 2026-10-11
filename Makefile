.PHONY: all clean fmt fmtcheck lint fix docs spec example-bookstore version tag

all: clean fmt lint docs spec

fmt:
	crystal tool format

fmtcheck:
	crystal tool format --check

spec:
	crystal spec -v

lib/ameba/bin/ameba:
	shards install
	cd lib/ameba && shards build ameba

lint: lib/ameba/bin/ameba
	lib/ameba/bin/ameba

fix: lib/ameba/bin/ameba
	lib/ameba/bin/ameba --fix

docs:
	crystal docs

bin/prostore:
	shards build prostore

# Seed examples/bookstore/bookstore.sqlite3 (fresh every run) and open it in
# the TUI browser — a self-contained schema exercising every RecordDetail
# editor kind (bool, enum_string, enum_int, @[Flags], FK, text).
example-bookstore: bin/prostore
	crystal run examples/bookstore/seed.cr
	DATABASE_URL=sqlite3://examples/bookstore/bookstore.sqlite3 bin/prostore browse

clean:
	rm -rf docs/

# Sync the VERSION constant in src/ to match shard.yml's version field.
# Bump shard.yml's version first, then run `make version`.
version:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	for f in $$(grep -rl '^[[:space:]]*VERSION[[:space:]]*=[[:space:]]*"[^"]*"' src/ 2>/dev/null); do \
		sed -E "s/^([[:space:]]*VERSION[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"$$V\"/" "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f"; \
		echo "updated $$f to $$V"; \
	done

# Create an annotated git tag "vX.Y.Z" from shard.yml's version field.
tag:
	@V=$$(grep '^version:' shard.yml | sed -E 's/^version:[[:space:]]*//'); \
	git tag -a "v$$V" -m "Release v$$V"; \
	echo "tagged v$$V"
