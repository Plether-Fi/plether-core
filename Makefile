PACKAGES := shared spot options perps
TEST_PACKAGES := spot options perps
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

$(addprefix test-, $(TEST_PACKAGES)):
	forge test --root packages/$(@:test-%=%)

test-integration:
	forge test --no-match-path 'test/fork/*'

coverage-spot coverage-options: COVERAGE_FLAGS := --ir-minimum
coverage-spot coverage-options: COVERAGE_TEST_FLAGS := --no-match-test 'testFuzz_|invariant_'
coverage-perps: COVERAGE_FLAGS := --ir-minimum
coverage-perps: COVERAGE_TEST_FLAGS := --no-match-test 'testFuzz_|invariant_|test_H01_UpdateMarkUsesPublishTime|test_GetTraderAccount_Withdrawable(Decreases|Drops)'

$(addprefix coverage-, $(COVERAGE_PACKAGES)):
	FOUNDRY_SRC=packages/$(@:coverage-%=%)/src \
	FOUNDRY_TEST=packages/$(@:coverage-%=%)/test \
	FOUNDRY_SCRIPT=integration/src forge coverage $(COVERAGE_FLAGS) $(COVERAGE_TEST_FLAGS)

fmt-check:
	forge fmt --check packages test script
