TOFU ?= tofu
YAMLLINT ?= yamllint
CHECK_JSONSCHEMA ?= check-jsonschema
CLOUD_CONFIG_SCHEMA ?= https://raw.githubusercontent.com/canonical/cloud-init/ubuntu/resolute-26.1.x/cloudinit/config/schemas/schema-cloud-config-v1.json
NETWORK_CONFIG_SCHEMA ?= https://raw.githubusercontent.com/canonical/cloud-init/ubuntu/resolute-26.1.x/cloudinit/config/schemas/schema-network-config-v2.json

.PHONY: help init fmt fmt-check tofu-validate host-render host-validate host-seed validate clean-rendered

help:
	@printf '%s\n' \
		'init             Initialize OpenTofu and its local backend' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check OpenTofu formatting' \
		'host-render      Render the local NoCloud host seed' \
		'host-validate    Render and validate the host seed' \
		'host-seed        Alias for the complete host seed workflow' \
		'tofu-validate    Validate OpenTofu configuration' \
		'validate         Run all local validation' \
		'clean-rendered   Remove only rendered host seed files'

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt

fmt-check:
	$(TOFU) fmt -check

tofu-validate:
	$(TOFU) validate

host-render:
	$(TOFU) apply -auto-approve

host-validate: host-render
	$(YAMLLINT) cloud-init/rendered
	$(CHECK_JSONSCHEMA) --force-filetype yaml --schemafile "$(CLOUD_CONFIG_SCHEMA)" cloud-init/rendered/user-data
	$(CHECK_JSONSCHEMA) --force-filetype yaml --schemafile "$(NETWORK_CONFIG_SCHEMA)" cloud-init/rendered/network-config

host-seed: host-validate

validate: fmt-check tofu-validate host-validate

clean-rendered:
	$(RM) -r cloud-init/rendered
