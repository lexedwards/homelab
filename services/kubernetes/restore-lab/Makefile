TOFU ?= tofu
PLAN_FILE ?= deployment.tfplan

.PHONY: init validate plan apply
init:
	$(TOFU) init
validate:
	$(TOFU) fmt -check
	$(TOFU) validate
	bash -n prepare.sh
	yamllint -c ../.yamllint user-data.tftpl
plan:
	$(TOFU) plan -out="$(PLAN_FILE)"
apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
