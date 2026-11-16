TOFU ?= tofu
YAMLLINT ?= yamllint
PYTHON ?= python3
HELM ?= helm
PLAN_FILE ?= deployment.tfplan
SCRIPT_ARGS ?= --help
OPERATOR_TARGETS := backup-recovery-custody check-control-plane check-policy-probe enroll-worker etcd-backup label-secrets-provider prepare-secret-auth restore-control-plane

.PHONY: help init fmt fmt-check tofu-validate test yaml-validate shell-validate validate nfs-chart-validate nfs-prepare secrets-csi-validate secrets-csi-prepare plan apply $(OPERATOR_TARGETS)

help:
	@printf '%s\n' \
		'init             Initialize providers; no infrastructure operations' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check formatting' \
		'tofu-validate    Validate the initialized root offline' \
		'test             Check primary-address selection and PTR-name transformations offline' \
		'yaml-validate    Lint cloud-init' \
		'shell-validate   Check guest script syntax' \
		'validate         Run all local checks without infrastructure access' \
		'nfs-chart-validate Render/check a previously downloaded NFS_CHART archive using HELM' \
		'nfs-prepare      Verify/render NFS_CHART and emit a new embedded-chart NFS_MANIFEST' \
		'secrets-csi-validate Verify/render local CSI_DRIVER_CHART and CSI_PROVIDER_CHART with SECRET_ENROLLMENT' \
		'secrets-csi-prepare Verify/render those inputs and emit private files in new SECRETS_OUTPUT' \
		'plan             Write an authorized online plan to PLAN_FILE' \
		'apply            Apply only a previously inspected, unchanged PLAN_FILE' \
		'Operator scripts (SCRIPT_ARGS defaults to --help; execution requires separate authorization):' \
		'backup-recovery-custody Attest independently recovered private files' \
		'check-control-plane Check the existing single-server cluster' \
		'check-policy-probe Probe an approved network-policy fixture' \
		'enroll-worker    Enroll one fresh worker over verified SSH' \
		'etcd-backup      Plan or explicitly execute backup/status operations' \
		'label-secrets-provider Check or explicitly apply exact worker directory labels' \
		'prepare-secret-auth Prepare private authentication inspection artifacts offline' \
		'restore-control-plane Plan or explicitly restore an owned fenced scratch VM'

init:
	$(TOFU) init
	$(MAKE) -C runtime init
	$(MAKE) -C restore-lab init

fmt:
	$(TOFU) fmt -recursive

fmt-check:
	$(TOFU) fmt -check -recursive

tofu-validate:
	$(TOFU) validate

test:
	$(TOFU) test

yaml-validate:
	$(YAMLLINT) cloud-init/node-baseline.yaml.tftpl
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
	$(YAMLLINT) platform/secrets-csi.yaml.tftpl
	$(YAMLLINT) examples/secrets-workloads.yaml

shell-validate:
	bash -n cloud-init/install-server.sh
	bash -n config/node-preflight.sh
	bash -n cloud-init/install-agent.sh

validate: fmt-check tofu-validate test yaml-validate shell-validate
	$(MAKE) -C runtime validate
	$(MAKE) -C restore-lab validate

nfs-chart-validate:
	test -f "$(NFS_CHART)"
	$(PYTHON) -B scripts/validate-nfs-chart.py --chart "$(NFS_CHART)" --helm "$(HELM)"

nfs-prepare:
	test -f "$(NFS_CHART)"
	test -n "$(NFS_MANIFEST)"
	$(PYTHON) -B scripts/validate-nfs-chart.py --chart "$(NFS_CHART)" --helm "$(HELM)" --output "$(NFS_MANIFEST)"

secrets-csi-validate:
	$(PYTHON) -B scripts/prepare-secrets-csi.py --driver-chart "$(CSI_DRIVER_CHART)" --provider-chart "$(CSI_PROVIDER_CHART)" --enrollment "$(SECRET_ENROLLMENT)" --helm "$(HELM)"

secrets-csi-prepare:
	test -n "$(SECRETS_OUTPUT)"
	$(PYTHON) -B scripts/prepare-secrets-csi.py --driver-chart "$(CSI_DRIVER_CHART)" --provider-chart "$(CSI_PROVIDER_CHART)" --enrollment "$(SECRET_ENROLLMENT)" --helm "$(HELM)" --output-dir "$(SECRETS_OUTPUT)"

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"

$(OPERATOR_TARGETS):
	@$(PYTHON) -B "scripts/$@.py" $(SCRIPT_ARGS)
