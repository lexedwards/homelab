TOFU ?= tofu
YAMLLINT ?= yamllint
PYTHON ?= python3
HELM ?= helm
PLAN_FILE ?= deployment.tfplan

.PHONY: help init fmt fmt-check tofu-validate test yaml-validate shell-validate validate nfs-chart-validate nfs-prepare plan apply

help:
	@printf '%s\n' \
		'init             Initialize providers; no infrastructure operations' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check formatting' \
		'tofu-validate    Validate the initialized root offline' \
		'test             Run mocked infrastructure, readiness and enrollment checks' \
		'yaml-validate    Lint cloud-init' \
		'shell-validate   Check guest script syntax' \
		'validate         Run all local checks without infrastructure access' \
		'nfs-chart-validate Render/check a previously downloaded NFS_CHART archive using HELM' \
		'nfs-prepare      Verify/render NFS_CHART and emit a new embedded-chart NFS_MANIFEST' \
		'plan             Write an authorized online plan to PLAN_FILE' \
		'apply            Apply only a previously inspected, unchanged PLAN_FILE'

init:
	$(TOFU) init

fmt:
	$(TOFU) fmt -recursive

fmt-check:
	$(TOFU) fmt -check -recursive

tofu-validate:
	$(TOFU) validate

test:
	$(TOFU) test
	$(PYTHON) -B -m unittest discover -s tests -p 'test_*.py'

yaml-validate:
	$(YAMLLINT) cloud-init/user-data.tftpl
	$(YAMLLINT) cloud-init/network-data.yaml
	$(YAMLLINT) cloud-init/worker-user-data.tftpl
	$(YAMLLINT) cloud-init/worker-network-data.yaml
	$(YAMLLINT) platform/kata.yaml
	$(YAMLLINT) examples/workloads.yaml
	$(YAMLLINT) platform/network-policy/
	$(YAMLLINT) examples/network-policy/
	$(YAMLLINT) examples/service-exposure.yaml
	$(YAMLLINT) platform/nfs.yaml.tftpl
	$(YAMLLINT) examples/nfs-workloads.yaml.tftpl

shell-validate:
	bash -n cloud-init/install-server.sh
	bash -n config/node-preflight.sh
	bash -n cloud-init/install-agent.sh

validate: fmt-check tofu-validate test yaml-validate shell-validate

nfs-chart-validate:
	test -f "$(NFS_CHART)"
	$(PYTHON) -B scripts/validate-nfs-chart.py --chart "$(NFS_CHART)" --helm "$(HELM)"

nfs-prepare:
	test -f "$(NFS_CHART)"
	test -n "$(NFS_MANIFEST)"
	$(PYTHON) -B scripts/validate-nfs-chart.py --chart "$(NFS_CHART)" --helm "$(HELM)" --output "$(NFS_MANIFEST)"

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
