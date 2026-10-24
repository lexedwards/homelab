TOFU ?= tofu
YAMLLINT ?= yamllint
PLAN_FILE ?= deployment.tfplan

.PHONY: help init fmt fmt-check tofu-validate cloud-init-validate test validate plan apply

help:
	@printf '%s\n' \
		'init                  Initialize OpenTofu and its local backend' \
		'fmt                   Format OpenTofu configuration' \
		'fmt-check             Check OpenTofu formatting' \
		'tofu-validate         Validate OpenTofu without contacting infrastructure' \
		'cloud-init-validate   Validate the cloud-init template' \
		'test                  Check settings with mocked providers (no infrastructure access)' \
		'validate              Run all local validation' \
		'plan                  Write an online plan to PLAN_FILE' \
		'apply                 Apply the previously reviewed PLAN_FILE'

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

test:
	$(TOFU) test

validate: fmt-check tofu-validate cloud-init-validate test

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
