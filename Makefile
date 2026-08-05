.PHONY: test validate package

test:
	./helpers/ai-dev-lxc/tests/smoke.sh

validate:
	./scripts/validate.sh

package: validate
	./scripts/package-release.sh
