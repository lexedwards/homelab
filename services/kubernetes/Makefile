TOFU ?= tofu
YAMLLINT ?= yamllint
PYTHON ?= python3
HELM ?= helm
ALLOY ?= alloy
PLAN_FILE ?= deployment.tfplan

.PHONY: help init fmt fmt-check tofu-validate test yaml-validate shell-validate publication-validate bootstrap-validate bootstrap-guard-check bootstrap-authorization-check validate nfs-chart-validate nfs-prepare secrets-csi-validate secrets-csi-prepare observability-chart-validate plan apply

help:
	@printf '%s\n' \
		'init             Initialize providers; no infrastructure operations' \
		'fmt              Format OpenTofu configuration' \
		'fmt-check        Check formatting' \
		'tofu-validate    Validate the initialized root offline' \
		'test             Check worker DNS, installation composition and snippet isolation offline' \
		'yaml-validate    Lint cloud-init' \
		'shell-validate   Check guest script syntax' \
		'publication-validate Check publication CLI loading and artifacts-root configuration offline' \
		'bootstrap-validate Check bootstrap/preparation CLI loading and recovery authorization offline' \
		'bootstrap-guard-check Exercise filesystem startup guards with bubblewrap; no network or native RKE2 execution' \
		'bootstrap-authorization-check Exercise rendered policy and guest client against disposable OpenBao; requires BAO_BINARY' \
		'validate         Run all local checks without infrastructure access' \
		'nfs-chart-validate Render/check a previously downloaded NFS_CHART archive using HELM' \
		'nfs-prepare      Verify/render NFS_CHART and emit a new embedded-chart NFS_MANIFEST' \
		'secrets-csi-validate Verify/render local CSI_DRIVER_CHART and CSI_PROVIDER_CHART with SECRET_ENROLLMENT' \
		'secrets-csi-prepare Verify/render those inputs and emit private files in new SECRETS_OUTPUT' \
		'observability-chart-validate Verify/render OBSERVABILITY_CHART and validate with chart-matching ALLOY' \
		'plan             Write an authorized online plan to PLAN_FILE' \
		'apply            Apply only a previously inspected, unchanged PLAN_FILE'

init:
	$(TOFU) init
	$(MAKE) -C runtime init
	$(MAKE) -C artifacts init
	$(MAKE) -C recovery init

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
	$(YAMLLINT) platform/observability/values.yaml

shell-validate:
	bash -n cloud-init/install-server.sh
	bash -n config/node-preflight.sh
	bash -n cloud-init/install-agent.sh
	bash -n scripts/kubeconfig-credentials.sh
	bash -n scripts/enroll-control-plane.sh
	bash -n scripts/bootstrap-credentials.sh
	bash -n scripts/check-bootstrap-guards.sh
	bash -n scripts/check-publication-overlays.sh
	bash -n scripts/check-control-plane-enrollment.sh
	bash -n scripts/check-bootstrap-authorization.sh

publication-validate:
	$(PYTHON) -B scripts/publish-kubeconfig.py --help >/dev/null
	$(PYTHON) -B scripts/issue-publication-credentials.py --help >/dev/null
	$(MAKE) -C artifacts validate

bootstrap-validate:
	$(PYTHON) -B scripts/rke2-bootstrap.py --help >/dev/null
	$(PYTHON) -B scripts/prepare-recovery.py --help >/dev/null
	$(PYTHON) -B scripts/backup-recovery-custody.py --help >/dev/null
	$(PYTHON) -B scripts/enroll-bootstrap.py --help >/dev/null
	$(PYTHON) -B scripts/complete-bootstrap.py --help >/dev/null
	$(PYTHON) -B scripts/install-enrollment.py --help >/dev/null
	$(MAKE) -C recovery validate

bootstrap-guard-check:
	bash scripts/check-bootstrap-guards.sh
	bash scripts/check-publication-overlays.sh
	bash scripts/check-control-plane-enrollment.sh

bootstrap-authorization-check:
	BAO_BINARY="$(BAO_BINARY)" bash scripts/check-bootstrap-authorization.sh

validate: fmt-check tofu-validate test yaml-validate shell-validate publication-validate bootstrap-validate bootstrap-guard-check
	$(MAKE) -C runtime validate

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

observability-chart-validate:
	$(PYTHON) -B scripts/validate-observability-chart.py --chart "$(OBSERVABILITY_CHART)" --helm "$(HELM)" --alloy "$(ALLOY)"

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
