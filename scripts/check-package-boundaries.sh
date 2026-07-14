#!/usr/bin/env bash
set -euo pipefail

failed=0

check_forbidden() {
    local package="$1"
    local forbidden="$2"
    local path="${3:-packages/${package}/src}"
    local boundary="${4:-${package}}"
    local matches

    if matches=$(rg -n "@plether/(${forbidden})/" "${path}" -g '*.sol'); then
        echo "Forbidden dependency from ${boundary}:"
        echo "${matches}"
        failed=1
    fi
}

check_forbidden shared 'spot|options|perps'
check_forbidden spot 'options|perps'
check_forbidden options 'perps'
check_forbidden perps 'spot|options'

check_forbidden shared 'spot|options|perps' packages/shared/test-support 'shared test support'
check_forbidden spot 'options|perps' packages/spot/test 'spot tests'
check_forbidden options 'perps' packages/options/test 'options tests'
check_forbidden perps 'spot|options' packages/perps/test 'perps tests'

if matches=$(
    rg -n '@plether/spot/' packages/options/src -g '*.sol' \
        | rg -v '@plether/spot/interfaces/ISyntheticSplitter\.sol'
); then
    echo "Options may depend only on the public spot ISyntheticSplitter API:"
    echo "${matches}"
    failed=1
fi

if matches=$(
    rg -n '@plether/spot/' packages/options/test -g '*.sol' \
        | rg -v '@plether/spot/interfaces/ISyntheticSplitter\.sol'
); then
    echo "Options tests may depend only on the public spot ISyntheticSplitter API:"
    echo "${matches}"
    failed=1
fi

if matches=$(rg -n '@plether/test-utils/' packages/*/src -g '*.sol'); then
    echo "Production package sources must not import test support:"
    echo "${matches}"
    failed=1
fi

if matches=$(rg -n '(from|import) "\.\.?/' packages/*/src -g '*.sol'); then
    echo "Package sources must use canonical @plether imports instead of relative imports:"
    echo "${matches}"
    failed=1
fi

if [ "${failed}" -ne 0 ]; then
    exit 1
fi

echo "Package dependency boundaries are valid."
