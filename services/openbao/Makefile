TOFU ?= tofu
YAMLLINT ?= yamllint
PYTHON ?= python3
BAO_BIN ?= bao
PLAN_FILE ?= deployment.tfplan

.PHONY: help init fmt fmt-check tofu-validate cloud-init-validate test server-test validate plan apply

help:
	@printf '%s\n' \
		'init                  Initialize OpenTofu and its local backend' \
		'fmt                   Format OpenTofu configuration' \
		'fmt-check             Check OpenTofu formatting' \
		'tofu-validate         Validate OpenTofu without contacting infrastructure' \
		'cloud-init-validate   Lint the cloud-init template and check installer syntax' \
		'test                  Run mocked infrastructure and readiness tests offline' \
		'server-test           Start a disposable loopback server using BAO_BIN; never initializes it' \
		'validate              Run all local validation' \
		'plan                  Write an online plan to PLAN_FILE (requires authorization)' \
		'apply                 Apply the previously reviewed PLAN_FILE (requires authorization)'

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt -recursive

fmt-check:
	$(TOFU) fmt -check -recursive

tofu-validate:
	$(TOFU) validate

cloud-init-validate:
	$(YAMLLINT) cloud-init/user-data.tftpl
	sh -n scripts/install.sh

test:
	$(TOFU) test
	$(PYTHON) -B -m unittest discover -s tests -p 'test_*.py'

server-test:
	$(PYTHON) -B tests/smoke-server.py --bao "$(BAO_BIN)" --tofu "$(TOFU)"

validate: fmt-check tofu-validate cloud-init-validate test server-test

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
