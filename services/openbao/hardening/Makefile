TOFU ?= tofu

.PHONY: init validate identity-metadata-check
init:
	$(TOFU) init

validate:
	$(TOFU) fmt -check
	$(TOFU) validate
	bash -n scripts/check-identity-metadata-access.sh

identity-metadata-check:
	BAO_BINARY="$(BAO_BINARY)" bash scripts/check-identity-metadata-access.sh
