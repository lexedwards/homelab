TOFU ?= tofu
YAMLLINT ?= yamllint
PLAN_FILE ?= deployment.tfplan

export OPENBAO_INIT_DIR OPENBAO_KEY_SHARES OPENBAO_KEY_THRESHOLD

.PHONY: help init fmt fmt-check tofu-validate cloud-init-validate shell-validate validate plan apply initialize-openbao

help:
	@printf '%s\n' \
		'init                  Initialize OpenTofu and its local backend' \
		'fmt                   Format OpenTofu configuration' \
		'fmt-check             Check OpenTofu formatting' \
		'tofu-validate         Validate OpenTofu without contacting infrastructure' \
		'cloud-init-validate   Lint YAML and check package helper/deploy-hook syntax' \
		'shell-validate        Check operator initialization procedure syntax (no API access)' \
		'validate              Run all local validation' \
		'plan                  Write an online plan to PLAN_FILE (requires authorization)' \
		'apply                 Apply the previously reviewed PLAN_FILE (requires authorization)' \
		'initialize-openbao    Initialize NEW storage with explicit OPENBAO_INIT_DIR, OPENBAO_KEY_SHARES, OPENBAO_KEY_THRESHOLD'

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
	sh -n scripts/install-package.sh
	sh -n scripts/deploy-certificate.sh

shell-validate:
	bash -n scripts/initialize.sh

validate: fmt-check tofu-validate cloud-init-validate shell-validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"

initialize-openbao:
	@bash scripts/initialize.sh "$${OPENBAO_INIT_DIR:?set OPENBAO_INIT_DIR}" "$${OPENBAO_KEY_SHARES:?set OPENBAO_KEY_SHARES}" "$${OPENBAO_KEY_THRESHOLD:?set OPENBAO_KEY_THRESHOLD}"
