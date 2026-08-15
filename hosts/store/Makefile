TOFU ?= tofu

.PHONY: help init fmt fmt-check tofu-validate validate

help:
	@printf '%s\n' \
		'init             Initialize OpenTofu and its local backend' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check OpenTofu formatting' \
		'tofu-validate    Validate OpenTofu configuration' \
		'validate         Run all local validation'

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt

fmt-check:
	$(TOFU) fmt -check

tofu-validate:
	$(TOFU) validate

validate: fmt-check tofu-validate
