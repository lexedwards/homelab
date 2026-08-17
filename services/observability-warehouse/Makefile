TOFU ?= tofu
YAMLLINT ?= yamllint
ALLOY ?= alloy
PLAN_FILE ?= deployment.tfplan
ALLOY_CONFIGS := config/alloy/config.alloy config/alloy/copilot.alloy

.PHONY: help init fmt fmt-check tofu-validate yaml-validate shell-validate alloy-validate validate plan apply

help:
	@printf '%s\n' \
		'init             Initialize OpenTofu and its local backend' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check OpenTofu formatting' \
		'tofu-validate    Validate OpenTofu without contacting Proxmox' \
		'yaml-validate    Lint cloud-init and service YAML templates' \
		'shell-validate   Check the Debian package installers' \
		'alloy-validate   Validate the Alloy configuration' \
		'validate         Run all local validation' \
		'plan             Write an online plan to PLAN_FILE' \
		'apply            Apply the previously reviewed PLAN_FILE'

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt

fmt-check:
	$(TOFU) fmt -check

tofu-validate:
	$(TOFU) validate

yaml-validate:
	$(YAMLLINT) cloud-init/user-data.tftpl cloud-init/collector-user-data.tftpl cloud-init/grafana-user-data.tftpl config/compose.yaml config/grafana-datasources.yaml.tftpl config/mimir.yaml.tftpl config/loki.yaml.tftpl config/tempo.yaml.tftpl

shell-validate:
	bash -n cloud-init/install-alloy-debian.sh
	bash -n cloud-init/install-grafana-debian.sh

alloy-validate:
	test -n "$(ALLOY_CONFIGS)"
	for config in $(ALLOY_CONFIGS); do $(ALLOY) fmt --test "$$config"; done
	MIMIR_URL=http://warehouse.invalid:9009/api/v1/push \
	LOKI_URL=http://warehouse.invalid:3100/loki/api/v1/push \
	TEMPO_ENDPOINT=warehouse.invalid:4317 \
	$(ALLOY) validate --stability.level=experimental config/alloy

validate: fmt-check tofu-validate yaml-validate shell-validate alloy-validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
