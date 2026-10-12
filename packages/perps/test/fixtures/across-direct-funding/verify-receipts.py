#!/usr/bin/env python3
"""Local-only transaction-receipt proof for the exact Across handler/emitter runtimes.

Requires Python stdlib, cast, anvil, and compiled AcrossDirectFundingToken /
MarginClearinghouse artifacts. Starts a fresh loopback-only Anvil without a fork,
installs reviewed runtime bytes, and never connects to an external RPC endpoint.
This tests the callback recipe, not SpokePool delivery or live API compatibility.
"""
import argparse
import json
import re
from pathlib import Path
import shutil
import socket
import subprocess
import time
import urllib.request


HANDLER = "0x0f7ae28de1c8532170ad4ee566b5801485c13a0e"
EMITTER = "0xbf75133b48b0a42ab9374027902e83c5e2949034"
BENEFICIARY = "0x000000000000000000000000000000000000beef"
HANDLER_HASH = "0x2a70f9d1b1c80cc0430bbffe16283cf067d915bee05f9812715cd94ad082b76a"
EMITTER_HASH = "0x833b49ceddf001f197603e23297ddc21147b7d9e61adbe812e1167b3a7fe2fe5"


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def word(n):
    return n.to_bytes(32, "big")


def address(value):
    return bytes.fromhex(value[2:]).rjust(32, b"\0")


def dynamic(value):
    return word(len(value)) + value + bytes((-len(value)) % 32)


def selector(signature):
    return bytes.fromhex(cast("sig", signature)[2:])


def runtime(path):
    text = Path(path).read_text().strip()
    if text.startswith("{"):
        return json.loads(text)["runtimeBytecode"]["onchainBytecode"]
    if text.startswith("// SPDX-License-Identifier:"):
        values = re.findall(r'return hex"([0-9a-fA-F]+)";', text)
        assert len(values) == 1, "runtime fixture must contain exactly one bytecode literal"
        return "0x" + values[0]
    assert text.startswith("0x"), "runtime must be hex, Solidity fixture, or Sourcify JSON"
    return text


def instructions(calls, fallback):
    encoded = [address(target) + word(96) + word(value) + dynamic(data)
               for target, data, value in calls]
    offsets, offset = [], 32 * len(calls)
    for item in encoded:
        offsets.append(word(offset))
        offset += len(item)
    array = word(len(calls)) + b"".join(offsets) + b"".join(encoded)
    return word(32) + word(64) + address(fallback) + array


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    fixture_dir = Path(__file__).resolve().parent
    parser.add_argument("--root", type=Path, default=fixture_dir.parents[4])
    parser.add_argument("--handler-runtime", default=fixture_dir / "ArbitrumMulticallHandlerRuntime.sol")
    parser.add_argument("--emitter-runtime", default=fixture_dir / "ArbitrumEventEmitterRuntime.sol")
    parser.add_argument("--report", type=Path, default=Path("/tmp/across-marker-receipt-proof.json"))
    args = parser.parse_args()
    assert shutil.which("cast") and shutil.which("anvil"), "cast and anvil are required"
    handler_code = runtime(args.handler_runtime)
    emitter_code = runtime(args.emitter_runtime)
    assert cast("keccak", handler_code) == HANDLER_HASH
    assert cast("keccak", emitter_code) == EMITTER_HASH
    artifact_paths = {
        "token": args.root / "packages/perps/out/AcrossDirectFunding.t.sol/AcrossDirectFundingToken.json",
        "clearinghouse": args.root / "packages/perps/out/MarginClearinghouse.sol/MarginClearinghouse.json",
    }
    bytecodes = {name: json.loads(path.read_text())["bytecode"]["object"]
                 for name, path in artifact_paths.items()}
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    endpoint = f"http://127.0.0.1:{port}"
    process = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(port), "--chain-id", "31337",
         "--hardfork", "cancun", "--silent"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    sequence = 0

    def rpc(method, params):
        nonlocal sequence
        sequence += 1
        payload = json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}).encode()
        request = urllib.request.Request(endpoint, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]

    try:
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError("anvil failed: " + process.stderr.read().decode())
            try:
                if rpc("eth_chainId", []) == "0x7a69":
                    break
            except (OSError, RuntimeError):
                time.sleep(0.05)
        else:
            raise RuntimeError("local Anvil startup timeout")
        sender = rpc("eth_accounts", [])[0]

        def send(data, target=None):
            transaction = {"from": sender, "data": data, "gas": "0x1c9c380"}
            if target:
                transaction["to"] = target
            tx_hash = rpc("eth_sendTransaction", [transaction])
            for _ in range(100):
                receipt = rpc("eth_getTransactionReceipt", [tx_hash])
                if receipt:
                    assert receipt["status"] == "0x1", receipt
                    return receipt
                time.sleep(0.02)
            raise RuntimeError("local receipt timeout")

        def invoke(target, signature, *values):
            return send(cast("calldata", signature, *map(str, values)), target)

        def read_uint(target, signature, *values):
            data = cast("calldata", signature, *map(str, values))
            return int(rpc("eth_call", [{"to": target, "data": data}, "latest"]), 16)

        rpc("anvil_setCode", [HANDLER, handler_code])
        rpc("anvil_setStorageAt", [HANDLER, "0x" + word(0).hex(), "0x" + word(1).hex()])
        rpc("anvil_setCode", [EMITTER, emitter_code])
        assert cast("keccak", rpc("eth_getCode", [HANDLER, "latest"])) == HANDLER_HASH
        assert cast("keccak", rpc("eth_getCode", [EMITTER, "latest"])) == EMITTER_HASH
        topics = {name: cast("keccak", signature) for name, signature in {
            "deposit": "Deposit(address,address,uint256)",
            "depositFor": "DepositFor(address,address,uint256)",
            "marker": "MetadataEmitted(bytes)",
            "callsFailed": "CallsFailed((address,bytes,uint256)[],address)",
            "drained": "DrainedTokens(address,address,uint256)",
            "transfer": "Transfer(address,address,uint256)",
        }.items()}
        outcomes = []
        for index, (name, pull_fail, reset_fail, fifth_fail) in enumerate([
            ("success", False, False, False),
            ("deposit_failure", True, False, False),
            ("reset_failure", False, True, False),
            ("failure_after_marker", False, False, True),
        ]):
            token = send(bytecodes["token"])["contractAddress"].lower()
            house = send(bytecodes["clearinghouse"] + address(token).hex())["contractAddress"].lower()
            delivered = 103_000_007 + index
            quote_id = word(index + 1)
            approve = selector("approve(address,uint256)") + address(house) + word(0)
            deposit = selector("depositFor(address,uint256)") + address(BENEFICIARY) + word(0)

            def balance_call(target, data):
                body = dynamic(data)
                return (HANDLER, selector("makeCallWithBalance(address,bytes,uint256,(address,uint256)[])")
                        + address(target) + word(128) + word(0) + word(128 + len(body))
                        + body + word(1) + address(token) + word(36), 0)

            calls = [balance_call(token, approve), balance_call(house, deposit),
                     (token, approve, 0),
                     (EMITTER, selector("emitData(bytes)") + word(32) + dynamic(quote_id), 0)]
            if fifth_fail:
                # The deployed emitter rejects empty data, after the fourth call emitted its marker.
                calls.append((EMITTER, selector("emitData(bytes)") + word(32) + dynamic(b""), 0))
            message = instructions(calls, BENEFICIARY)
            invoke(token, "mint(address,uint256)", HANDLER, delivered)
            invoke(token, "setFailures(bool,bool,bool)", str(pull_fail).lower(), str(reset_fail).lower(), "false")
            callback = (selector("handleV3AcrossMessage(address,uint256,address,bytes)") + address(token)
                        + word(100_000_000) + address(sender) + word(128) + dynamic(message))
            receipt = send("0x" + callback.hex(), HANDLER)
            logs = receipt["logs"]

            def matching(key, emitter):
                return [log for log in logs if log["address"].lower() == emitter.lower()
                        and log["topics"] and log["topics"][0] == topics[key]]

            observed = {key: matching(key, emitter) for key, emitter in {
                "deposit": house, "depositFor": house, "marker": EMITTER,
                "callsFailed": HANDLER, "drained": HANDLER,
            }.items()}
            balances = {
                "handler": read_uint(token, "balanceOf(address)", HANDLER),
                "beneficiary": read_uint(token, "balanceOf(address)", BENEFICIARY),
                "clearinghouse": read_uint(token, "balanceOf(address)", house),
                "settlementCredit": read_uint(house, "balanceUsdc(address)", BENEFICIARY),
                "allowance": read_uint(token, "allowance(address,address)", HANDLER, house),
            }
            success = name == "success"
            expected_counts = {"deposit": int(success), "depositFor": int(success), "marker": int(success),
                               "callsFailed": int(not success), "drained": int(not success)}
            assert {key: len(value) for key, value in observed.items()} == expected_counts, (name, observed)
            assert balances == {"handler": 0, "beneficiary": 0 if success else delivered,
                                "clearinghouse": delivered if success else 0,
                                "settlementCredit": delivered if success else 0, "allowance": 0}, (name, balances)
            if success:
                first, second, marker = observed["deposit"][0], observed["depositFor"][0], observed["marker"][0]
                assert first["topics"] == [topics["deposit"], "0x" + address(BENEFICIARY).hex(), "0x" + address(token).hex()]
                assert second["topics"] == [topics["depositFor"], "0x" + address(HANDLER).hex(), "0x" + address(BENEFICIARY).hex()]
                assert first["data"] == second["data"] == "0x" + word(delivered).hex()
                assert marker["topics"] == [topics["marker"]]
                assert marker["data"] == "0x" + (word(32) + dynamic(quote_id)).hex()
                assert int(first["logIndex"], 16) + 1 == int(second["logIndex"], 16) < int(marker["logIndex"], 16)
            else:
                drain = observed["drained"][0]
                assert drain["topics"] == [topics["drained"], "0x" + address(BENEFICIARY).hex(),
                                           "0x" + address(token).hex(), "0x" + word(delivered).hex()]
                transfers = [log for log in matching("transfer", token)
                             if log["topics"] == [topics["transfer"], "0x" + address(HANDLER).hex(),
                                                  "0x" + address(BENEFICIARY).hex()]
                             and log["data"] == "0x" + word(delivered).hex()]
                assert len(transfers) == 1
                assert int(observed["callsFailed"][0]["logIndex"], 16) < int(transfers[0]["logIndex"], 16) < int(drain["logIndex"], 16)
            outcomes.append({"name": name, "delivered": delivered, "quoteId": "0x" + quote_id.hex(),
                             "token": token, "clearinghouse": house, "message": "0x" + message.hex(),
                             "eventCounts": expected_counts, "balances": balances, "receipt": receipt})
            print(json.dumps({"scenario": name, "passed": True, "events": expected_counts}), flush=True)
        report = {"passed": True, "scope": "Fresh local Anvil; no fork or external transactions; actual receipt logs, not trace logs",
                  "chainId": 31337, "runtimeHashes": {"handler": HANDLER_HASH, "emitter": EMITTER_HASH},
                  "artifactCreationHashes": {name: cast("keccak", data) for name, data in bytecodes.items()},
                  "scenarios": outcomes}
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print("Report: " + str(args.report), flush=True)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
