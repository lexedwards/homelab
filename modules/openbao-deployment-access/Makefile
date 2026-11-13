PYTHON ?= python3
TOFU ?= tofu

.PHONY: test validate deployment-auth-test

test:
	$(PYTHON) -B -m unittest discover -s tests -p 'test_*.py'

validate: test
	$(TOFU) fmt -check -recursive
	$(PYTHON) -B ../../scripts/check-service-boundaries.py

deployment-auth-test:
	test -n "$(BAO_TEST_BINARY)"
	BAO_TEST_BINARY="$(BAO_TEST_BINARY)" $(PYTHON) -B -m unittest discover -s tests -p 'test_deployment_auth.py'
