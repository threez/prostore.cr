.PHONY: spec docs examples

all: clean fmt lint docs spec examples montage.png

fmt:
	crystal tool format

spec:
	crystal spec -v

AMEBA=./lib/ameba/bin/ameba

$(AMEBA): $(AMEBA).cr
	crystal build -o $@ $(AMEBA).cr

lint: $(AMEBA)
	$(AMEBA)

docs:
	crystal docs

clean:
	rm -rf docs