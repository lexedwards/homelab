TOFU ?= tofu
YAMLLINT ?= yamllint
COMPOSE ?= docker compose
PLAN_FILE ?= deployment.tfplan

.PHONY: help init fmt fmt-check tofu-validate cloud-init-validate compose-validate validate plan apply

help:
	@printf '%s\n' \
		'init                  Initialize OpenTofu and its local backend' \
		'fmt                   Format OpenTofu configuration' \
		'fmt-check             Check OpenTofu formatting' \
		'tofu-validate         Validate OpenTofu without contacting Incus' \
		'cloud-init-validate   Lint cloud-init and Compose YAML' \
		'compose-validate      Validate Compose configuration without a daemon' \
		'validate              Run all local validation' \
		'plan                  Write an online plan to PLAN_FILE' \
		'apply                 Apply the previously reviewed PLAN_FILE'

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt

fmt-check:
	$(TOFU) fmt -check

tofu-validate:
	$(TOFU) validate

cloud-init-validate:
	$(YAMLLINT) cloud-init/user-data.tftpl config/compose.yaml

compose-validate:
	$(COMPOSE) --file config/compose.yaml config --quiet

validate: fmt-check tofu-validate cloud-init-validate compose-validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
