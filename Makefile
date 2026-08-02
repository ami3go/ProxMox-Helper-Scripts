SHELL := /usr/bin/env bash

.PHONY: validate catalog package site clean new-helper

validate:
	./scripts/validate.sh

catalog:
	./scripts/generate-catalog.py

package: catalog validate
	./scripts/package-release.sh

site: catalog
	./scripts/build-site.sh

new-helper:
	./scripts/new-helper.sh

clean:
	rm -rf dist _site scripts/__pycache__
