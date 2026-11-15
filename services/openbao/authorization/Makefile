TOFU ?= tofu

.PHONY: init validate
init:
	$(TOFU) init

validate:
	$(TOFU) fmt -check
	$(TOFU) validate
