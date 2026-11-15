TOFU ?= tofu
PLAN_FILE ?= deployment.tfplan

.PHONY: init fmt-check tofu-validate validate plan apply

init:
	$(TOFU) init

fmt-check:
	$(TOFU) fmt -check -recursive
	$(TOFU) fmt -check -recursive ../../../modules

tofu-validate:
	$(TOFU) validate

validate: fmt-check tofu-validate
	$(MAKE) -C ../../../modules/openbao-deployment-access validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
