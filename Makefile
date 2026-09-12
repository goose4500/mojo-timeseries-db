MOJO ?= mojo
PYTHON ?= python3

.PHONY: all test demo example format clean

all: build/tsdb

build/tsdb: tsdb.mojo engine.mojo storage.mojo aggregations.mojo
	mkdir -p build
	$(MOJO) build tsdb.mojo -o $@

build/tests: tests.mojo engine.mojo storage.mojo aggregations.mojo
	mkdir -p build
	$(MOJO) build tests.mojo -o $@

test: build/tsdb build/tests
	./build/tests
	$(PYTHON) -m unittest discover -s tests -v
	$(MOJO) -I . examples/custom_aggregation.mojo

demo: build/tsdb
	bash scripts/demo.sh

example:
	$(MOJO) -I . examples/custom_aggregation.mojo

format:
	$(MOJO) format *.mojo examples/*.mojo

clean:
	rm -rf build
