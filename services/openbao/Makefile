TOFU ?= tofu
YAMLLINT ?= yamllint
PYTHON ?= python3
PLAN_FILE ?= deployment.tfplan

.PHONY: help init fmt fmt-check tofu-validate cloud-init-validate test validate deployment-auth-test plan apply

help:
	@printf '%s\n' \
		'init                  Initialize OpenTofu and its local backend' \
		'fmt                   Format OpenTofu configuration' \
		'fmt-check             Check OpenTofu formatting' \
		'tofu-validate         Validate OpenTofu without contacting infrastructure' \
		'cloud-init-validate   Lint the cloud-init template and check installer syntax' \
		'test                  Run mocked infrastructure and readiness tests offline' \
		'deployment-auth-test   Run isolated real OpenBao 2.7.2 authorization tests; requires BAO_TEST_BINARY' \
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
	sh -n scripts/deploy-certificate.sh

test:
	$(TOFU) test
	$(PYTHON) -B -m unittest discover -s tests -p 'test_*.py'

validate: fmt-check tofu-validate cloud-init-validate test

deployment-auth-test:
	test -n "$(BAO_TEST_BINARY)"
	BAO_TEST_BINARY="$(BAO_TEST_BINARY)" $(PYTHON) -B -m unittest discover -s tests -p 'test_deployment_auth.py'

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
