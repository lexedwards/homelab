TOFU ?= tofu
PYTHON ?= python3
PLAN_FILE ?= deployment.tfplan

.PHONY: init fmt-check tofu-validate test validate plan apply

init:
	$(TOFU) init

fmt-check:
	$(TOFU) fmt -check -recursive

tofu-validate:
	$(TOFU) validate

test:
	$(TOFU) test
	$(PYTHON) -B -m unittest discover -s tests -p 'test_*.py'

validate: fmt-check tofu-validate test

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
