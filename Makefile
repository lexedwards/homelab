PYTHON ?= python3

.PHONY: docs-check docs-test docs-render

docs-check:
	$(PYTHON) scripts/check-documentation.py

docs-test:
	$(PYTHON) -m unittest discover -s tests

docs-render:
	$(PYTHON) scripts/check-documentation.py --render
