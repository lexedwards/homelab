PYTHON ?= python3
TOFU ?= tofu

.PHONY: validate

validate:
	$(TOFU) fmt -check -recursive
	$(PYTHON) -B ../../scripts/check-service-boundaries.py
