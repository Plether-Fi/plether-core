PACKAGES := shared spot options perps perps-aa
TEST_PACKAGES := spot options perps perps-aa
COVERAGE_PACKAGES := spot options perps

.PHONY: build build-packages check-boundaries test test-packages test-integration fmt-check \
	$(addprefix build-, $(PACKAGES)) $(addprefix test-, $(TEST_PACKAGES)) \
	$(addprefix coverage-, $(COVERAGE_PACKAGES))

build:
	forge build

build-packages: $(addprefix build-, $(PACKAGES))

$(addprefix build-, $(PACKAGES)):
	forge build --skip test --skip script --root packages/$(@:build-%=%)

check-boundaries:
	bash scripts/check-package-boundaries.sh

test: test-packages test-integration

test-packages: $(addprefix test-, $(TEST_PACKAGES))

$(addprefix test-, $(filter-out perps,$(TEST_PACKAGES))):
	forge test --root packages/$(@:test-%=%)

test-integration:
	forge test --no-match-path 'test/fork/*'

coverage-spot coverage-options coverage-perps: COVERAGE_FLAGS := --ir-minimum
coverage-spot coverage-options: COVERAGE_TEST_FLAGS := --no-match-test 'testFuzz_|invariant_'

coverage-spot coverage-options:
	FOUNDRY_SRC=packages/$(@:coverage-%=%)/src \
	FOUNDRY_TEST=packages/$(@:coverage-%=%)/test \
	FOUNDRY_SCRIPT=integration/src forge coverage $(COVERAGE_FLAGS) $(COVERAGE_TEST_FLAGS)

coverage-perps:
	bash scripts/run-perps-coverage.sh $(COVERAGE_FLAGS)

fmt-check:
	forge fmt --check packages test script

.PHONY: test-perps-quick test-perps-ci test-perps-audit test-perps-fork check-perps-tests
check-perps-tests:
	python3 scripts/check-perps-test-map.py
	python3 -m unittest discover -s scripts -p 'test_perps_runners.py'
	python3 scripts/perps-test-inventory.py

test-perps: test-perps-quick

test-perps-quick:
	FOUNDRY_PROFILE=quick bash scripts/run-perps-fast-tests.sh

test-perps-ci:
	FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=0xdeadbeef bash scripts/run-perps-fast-tests.sh

test-perps-audit:
	bash scripts/run-perps-audit-tests.sh

test-perps-fork:
	bash scripts/run-perps-fork-tests.sh
