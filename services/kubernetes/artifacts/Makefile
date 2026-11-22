TOFU ?= tofu

.PHONY: init fmt validate

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt

validate:
	$(TOFU) fmt -check
	$(TOFU) validate
