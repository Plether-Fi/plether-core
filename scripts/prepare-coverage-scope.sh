#!/usr/bin/env bash
set -euo pipefail

scope="${1:-}"
hidden_dir=".coverage-hidden/${scope}"

move_path() {
    local path="$1"
    if [ ! -e "${path}" ]; then
        return
    fi

    mkdir -p "${hidden_dir}/$(dirname "${path}")"
    mv "${path}" "${hidden_dir}/${path}"
}

move_glob() {
    local path
    shopt -s nullglob
    for path in "$@"; do
        move_path "${path}"
    done
    shopt -u nullglob
}

move_dir_files_except() {
    local dir="$1"
    shift
    local path basename keep keep_file

    shopt -s nullglob
    for path in "${dir}"/*.sol; do
        basename="$(basename "${path}")"
        keep=0
        for keep_file in "$@"; do
            if [ "${basename}" = "${keep_file}" ]; then
                keep=1
                break
            fi
        done

        if [ "${keep}" -eq 0 ]; then
            move_path "${path}"
        fi
    done
    shopt -u nullglob
}

if [ -z "${scope}" ]; then
    echo "usage: $0 <core|perps|options>" >&2
    exit 2
fi

rm -rf "${hidden_dir}"
mkdir -p "${hidden_dir}"

move_path script
move_path test/fork

case "${scope}" in
    core)
        move_path src/perps
        move_path src/options
        move_path test/perps
        move_path test/scripts
        move_path test/options
        move_path test/utils/OptionsMocks.sol
        move_path test/utils/OptionsTestSetup.sol
        move_path test/utils/OrderRouterDebugLens.sol
        ;;
    perps)
        move_path src/base
        move_path src/options
        move_glob src/*.sol
        move_dir_files_except src/interfaces AggregatorV3Interface.sol ICurvePool.sol IPyth.sol
        move_dir_files_except src/libraries DecimalConstants.sol OracleLib.sol
        move_dir_files_except src/oracles BasketOracle.sol
        move_glob test/*.sol
        move_dir_files_except test/mocks MockPyth.sol MockToken.sol MockUSDC.sol
        move_dir_files_except test/utils MockOracle.sol OrderRouterDebugLens.sol
        move_path test/options
        move_path test/oracles
        move_path test/perps/invariant
        move_path test/scripts
        move_path test/utils/OptionsMocks.sol
        move_path test/utils/OptionsTestSetup.sol
        ;;
    options)
        move_path src/perps
        move_glob src/*.sol
        move_dir_files_except src/base FlashLoanBase.sol
        move_dir_files_except src/interfaces AggregatorV3Interface.sol ICurvePool.sol IMorpho.sol ISyntheticSplitter.sol
        move_dir_files_except src/libraries DecimalConstants.sol OracleLib.sol
        move_dir_files_except src/oracles SettlementOracle.sol
        move_glob test/*.sol
        move_path test/mocks
        move_dir_files_except test/utils MockOracle.sol MockUSDCPermit.sol OptionsMocks.sol OptionsTestSetup.sol
        move_path test/perps
        move_path test/oracles
        move_path test/scripts
        move_path test/utils/OrderRouterDebugLens.sol
        ;;
    *)
        echo "unknown coverage scope: ${scope}" >&2
        exit 2
        ;;
esac
