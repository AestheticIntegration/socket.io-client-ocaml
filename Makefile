.PHONY: build
build:
	ocaml pkg/pkg.ml build

.PHONY: test
test:
	ocaml pkg/pkg.ml test

.PHONY: examples
examples:
	ocaml pkg/pkg.ml build --build-examples true

.PHONY: example-engineio-server
example-engineio-server:
	cd examples/engineio && DEBUG=engine* node index.js

.PHONY: example-engineio-client
example-engineio-client: examples
	./_build/examples/engineio/client.native

.PHONY: dev-setup
dev-setup:
	opam pin add . --no-action --yes
	opam install ocaml-engineio-client --deps-only
