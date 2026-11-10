TOFU ?= tofu
YAMLLINT ?= yamllint
PYTHON ?= python3
PLAN_FILE ?= deployment.tfplan

.PHONY: help init fmt fmt-check tofu-validate test yaml-validate shell-validate validate plan apply

help:
	@printf '%s\n' \
		'init             Initialize providers; no infrastructure operations' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check formatting' \
		'tofu-validate    Validate the initialized root offline' \
		'test             Run mocked infrastructure, readiness and isolated boot tests' \
		'yaml-validate    Lint cloud-init' \
		'shell-validate   Check guest script syntax' \
		'validate         Run all local checks without infrastructure access' \
		'plan             Write an authorized online plan to PLAN_FILE' \
		'apply            Apply only a previously inspected, unchanged PLAN_FILE'

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt -recursive

fmt-check:
	$(TOFU) fmt -check -recursive

tofu-validate:
	$(TOFU) validate

test:
	$(TOFU) test
	$(PYTHON) -B -m unittest discover -s tests -p 'test_*.py'

yaml-validate:
	$(YAMLLINT) cloud-init/user-data.tftpl
	$(YAMLLINT) cloud-init/network-data.yaml

shell-validate:
	bash -n cloud-init/install-server.sh
	bash -n config/node-preflight.sh

validate: fmt-check tofu-validate test yaml-validate shell-validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
