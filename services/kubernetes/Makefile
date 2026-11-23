TOFU ?= tofu
PYTHON ?= python3
HELM ?= helm
ALLOY ?= alloy
ROOTS := bootstrap infrastructure runtime
CHECK_ROOTS := $(ROOTS) examples/secret-delivery

.PHONY: help init fmt validate test nfs-chart-validate nfs-prepare secrets-csi-validate secrets-csi-prepare observability-chart-validate

help:
	@printf '%s\n' \
		'init       Initialize deployment roots and the optional example for local checks' \
		'fmt        Format the three roots' \
		'validate   Run local validation, tests and service-boundary checks' \
		'test       Run native mocked OpenTofu tests' \
		'Deploy explicitly from bootstrap/, infrastructure/ or runtime/ using an inspected saved plan.'

init:
	@set -e; for root in $(CHECK_ROOTS); do $(MAKE) -C $$root init; done

fmt:
	@set -e; for root in $(CHECK_ROOTS); do $(TOFU) -chdir=$$root fmt -recursive; done

validate:
	@set -e; for root in $(CHECK_ROOTS); do $(MAKE) -C $$root validate; done
	$(PYTHON) -B ../../scripts/check-service-boundaries.py

test:
	@set -e; for root in $(ROOTS); do $(TOFU) -chdir=$$root test; done

nfs-chart-validate:
	$(PYTHON) -B scripts/charts/validate-nfs-chart.py --chart "$(NFS_CHART)" --helm "$(HELM)"

nfs-prepare:
	test -n "$(NFS_MANIFEST)"
	$(PYTHON) -B scripts/charts/validate-nfs-chart.py --chart "$(NFS_CHART)" --helm "$(HELM)" --output "$(NFS_MANIFEST)"

secrets-csi-validate:
	$(PYTHON) -B scripts/secrets/prepare-secrets-csi.py --driver-chart "$(CSI_DRIVER_CHART)" --provider-chart "$(CSI_PROVIDER_CHART)" --enrollment "$(SECRET_ENROLLMENT)" --helm "$(HELM)"

secrets-csi-prepare:
	test -n "$(SECRETS_OUTPUT)"
	$(PYTHON) -B scripts/secrets/prepare-secrets-csi.py --driver-chart "$(CSI_DRIVER_CHART)" --provider-chart "$(CSI_PROVIDER_CHART)" --enrollment "$(SECRET_ENROLLMENT)" --helm "$(HELM)" --output-dir "$(SECRETS_OUTPUT)"

observability-chart-validate:
	$(PYTHON) -B scripts/charts/validate-observability-chart.py --chart "$(OBSERVABILITY_CHART)" --helm "$(HELM)" --alloy "$(ALLOY)"
