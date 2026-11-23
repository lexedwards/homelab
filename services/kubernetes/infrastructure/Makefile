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
		'publication-validate Check integrated publication/credential CLI loading offline' \
		'bootstrap-validate Check bootstrap/preparation CLI loading offline' \
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
	$(YAMLLINT) ../platform/kata.yaml
	$(YAMLLINT) ../examples/workloads.yaml
	$(YAMLLINT) ../platform/network-policy/
	$(YAMLLINT) ../examples/network-policy/
	$(YAMLLINT) ../examples/service-exposure.yaml
	$(YAMLLINT) ../platform/nfs.yaml.tftpl
	$(YAMLLINT) ../examples/nfs-workloads.yaml.tftpl
	$(YAMLLINT) ../platform/secrets-csi.yaml.tftpl
	$(YAMLLINT) ../examples/secrets-workloads.yaml
	$(YAMLLINT) ../platform/observability/values.yaml

shell-validate:
	bash -n cloud-init/install-server.sh
	bash -n config/node-preflight.sh
	bash -n cloud-init/install-agent.sh
	bash -n ../scripts/bootstrap/enroll-control-plane.sh
	bash -n ../scripts/bootstrap/bootstrap-credentials.sh
	bash -n ../scripts/checks/check-bootstrap-guards.sh
	bash -n ../scripts/checks/check-publication-overlays.sh
	bash -n ../scripts/checks/check-control-plane-enrollment.sh
	bash -n ../scripts/checks/check-bootstrap-authorization.sh

publication-validate:
	$(PYTHON) -B ../scripts/bootstrap/publish-kubeconfig.py --help >/dev/null
	$(PYTHON) -B ../scripts/bootstrap/issue-storage-credentials.py --help >/dev/null

bootstrap-validate:
	$(PYTHON) -B ../scripts/bootstrap/rke2-bootstrap.py --help >/dev/null
	$(PYTHON) -B ../scripts/bootstrap/prepare-recovery.py --help >/dev/null
	$(PYTHON) -B ../scripts/bootstrap/backup-recovery-custody.py --help >/dev/null
	$(PYTHON) -B ../scripts/bootstrap/enroll-bootstrap.py --help >/dev/null
	$(PYTHON) -B ../scripts/bootstrap/complete-bootstrap.py --help >/dev/null
	$(PYTHON) -B ../scripts/bootstrap/install-enrollment.py --help >/dev/null

bootstrap-guard-check:
	bash ../scripts/checks/check-bootstrap-guards.sh
	bash ../scripts/checks/check-publication-overlays.sh
	bash ../scripts/checks/check-control-plane-enrollment.sh

bootstrap-authorization-check:
	BAO_BINARY="$(BAO_BINARY)" bash ../scripts/checks/check-bootstrap-authorization.sh

validate: fmt-check tofu-validate test yaml-validate shell-validate publication-validate bootstrap-validate bootstrap-guard-check

nfs-chart-validate:
	test -f "$(NFS_CHART)"
	$(MAKE) -C .. nfs-chart-validate

nfs-prepare:
	test -f "$(NFS_CHART)"
	test -n "$(NFS_MANIFEST)"
	$(MAKE) -C .. nfs-prepare

secrets-csi-validate:
	$(MAKE) -C .. secrets-csi-validate

secrets-csi-prepare:
	test -n "$(SECRETS_OUTPUT)"
	$(MAKE) -C .. secrets-csi-prepare

observability-chart-validate:
	$(MAKE) -C .. observability-chart-validate

plan:
	$(TOFU) plan -out="$(PLAN_FILE)"

apply:
	test -f "$(PLAN_FILE)"
	$(TOFU) apply "$(PLAN_FILE)"
