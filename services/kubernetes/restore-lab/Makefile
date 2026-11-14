TOFU ?= tofu
PYTHON ?= python3
PLAN_FILE ?= deployment.tfplan

.PHONY: init validate plan apply
init:
	$(TOFU) init
validate:
	$(TOFU) fmt -check
	$(TOFU) validate
	$(TOFU) test
	bash -n prepare.sh
	yamllint -c ../.yamllint user-data.tftpl
	$(PYTHON) -B -m unittest discover -s ../tests -p test_restore_control_plane.py
plan:
	$(TOFU) plan -out="$(PLAN_FILE)"
apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
