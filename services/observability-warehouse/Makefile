TOFU ?= tofu
YAMLLINT ?= yamllint
ALLOY ?= alloy
COMPOSE ?= docker compose
PLAN_FILE ?= deployment.tfplan
ALLOY_CONFIGS := config/alloy/config.alloy config/alloy/copilot.alloy

.PHONY: help init fmt fmt-check tofu-validate yaml-validate shell-validate alloy-validate compose-validate validate plan apply

help:
	@printf '%s\n' \
		'init             Initialize OpenTofu and its local backend' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check OpenTofu formatting' \
		'tofu-validate    Validate OpenTofu without contacting Proxmox' \
		'yaml-validate    Lint cloud-init and service YAML templates' \
		'shell-validate   Check SSH enrollment and guest credential script syntax' \
		'alloy-validate   Validate the Alloy configuration' \
		'compose-validate Validate Compose without credentials or a running daemon' \
		'validate         Run all local validation' \
		'plan             Write an online plan to PLAN_FILE' \
		'apply            Apply the previously reviewed PLAN_FILE'

init:
	$(TOFU) init
	$(MAKE) -C access init

fmt:
	$(TOFU) fmt -recursive

fmt-check:
	$(TOFU) fmt -check -recursive

tofu-validate:
	$(TOFU) validate

yaml-validate:
	$(YAMLLINT) cloud-init/user-data.tftpl cloud-init/collector-user-data.tftpl cloud-init/grafana-user-data.tftpl config/compose.yaml config/grafana-datasources.yaml.tftpl config/mimir.yaml.tftpl config/loki.yaml.tftpl config/tempo.yaml.tftpl

alloy-validate:
	test -n "$(ALLOY_CONFIGS)"
	for config in $(ALLOY_CONFIGS); do $(ALLOY) fmt --test "$$config"; done
	MIMIR_URL=http://warehouse.invalid:9009/api/v1/push \
	LOKI_URL=http://warehouse.invalid:3100/loki/api/v1/push \
	TEMPO_ENDPOINT=warehouse.invalid:4317 \
	$(ALLOY) validate --stability.level=experimental config/alloy

compose-validate:
	$(COMPOSE) --env-file /dev/null --file config/compose.yaml config --no-interpolate --quiet

shell-validate:
	bash -n scripts/warehouse-credentials.sh
	bash -n scripts/enroll-warehouse.sh

validate: fmt-check tofu-validate yaml-validate shell-validate alloy-validate compose-validate
	$(MAKE) -C access validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
