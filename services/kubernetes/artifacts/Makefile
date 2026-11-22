TOFU ?= tofu
PLAN_FILE ?= deployment.tfplan

.PHONY: init fmt validate plan apply

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt

validate:
	$(TOFU) fmt -check
	$(TOFU) validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
