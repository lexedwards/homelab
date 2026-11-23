TOFU ?= tofu
PLAN_FILE ?= deployment.tfplan

.PHONY: init fmt fmt-check tofu-validate test validate plan apply

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt -recursive

test:
	$(TOFU) test

fmt-check:
	$(TOFU) fmt -check -recursive
	$(TOFU) fmt -check -recursive ../../../modules

tofu-validate:
	$(TOFU) validate

validate: fmt-check tofu-validate test
	$(MAKE) -C ../../../modules/openbao-deployment-access validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
