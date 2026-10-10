"""Stream Forge JSON without retaining successful execution traces in memory.

Foundry 1.5.1's --suppress-successful-traces affects display, but its JSON still
contains successful invariant traces. Preserve all failure evidence and metrics.
"""

import json
import re

TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[{}\[\]:,]|[^\s{}\[\]:,"]+')
SPACE = re.compile(r"\s+")


def tokens(source, first="", chunk_size=65536):
    buffer, position, eof = first, 0, False
    while True:
        whitespace = SPACE.match(buffer, position)
        if whitespace:
            position = whitespace.end()
        if position == len(buffer):
            if eof:
                return
            buffer, position = source.read(chunk_size), 0
            eof = not buffer
            continue
        match = TOKEN.match(buffer, position)
        # Scalars and strings split across read boundaries must be completed.
        if match and (match.end() < len(buffer) or eof or match.group()[-1:] in '{}[]:,"'):
            token = match.group()
            position = match.end()
            yield token
            continue
        if eof:
            raise ValueError("incomplete JSON token")
        more = source.read(chunk_size)
        buffer = buffer[position:] + more
        position = 0
        eof = not more


def compact(source, output, diagnostics, redact=lambda value: value, chunk_size=65536):
    # Forge can emit warnings before its JSON document. Retain them separately.
    first = source.read(1)
    while first and first != "{":
        if not first.isspace():
            diagnostics.write(redact(first + source.readline()))
            diagnostics.flush()
        first = source.read(1)
    if not first:
        raise ValueError("Forge did not emit a JSON document")
    iterator = iter(tokens(source, first, chunk_size))
    removed = 0

    def take():
        try:
            return next(iterator)
        except StopIteration as error:
            raise ValueError("incomplete JSON document") from error

    def emit(token):
        output.write(redact(token))

    def skip_value():
        token = take()
        depth = int(token in ("{", "["))
        while depth:
            token = take()
            depth += int(token in ("{", "[")) - int(token in ("}", "]"))

    def value(path, token=None):
        nonlocal removed
        token = take() if token is None else token
        emit(token)
        if token == "{":
            status = None
            key = take()
            if key == "}":
                emit(key)
                return
            while True:
                name = json.loads(key)
                if not isinstance(name, str) or take() != ":":
                    raise ValueError("invalid JSON object")
                emit(key)
                emit(":")
                result = len(path) == 3 and path[1] == "test_results"
                if result and name == "status":
                    status_token = take()
                    status = json.loads(status_token)
                    emit(status_token)
                elif result and name == "traces" and status == "Success":
                    skip_value()
                    emit("[]")
                    removed += 1
                else:
                    value(path + (name,))
                separator = take()
                emit(separator)
                if separator == "}":
                    break
                if separator != ",":
                    raise ValueError("invalid JSON object separator")
                key = take()
            output.flush()
        elif token == "[":
            item = take()
            if item == "]":
                emit(item)
                return
            while True:
                value(path + ("[]",), item)
                separator = take()
                emit(separator)
                if separator == "]":
                    break
                if separator != ",":
                    raise ValueError("invalid JSON array separator")
                item = take()
        else:
            json.loads(token)  # Reject truncated/invalid primitive values.

    value(())
    if next(iterator, None) is not None:
        raise ValueError("unexpected content after Forge JSON")
    output.write("\n")
    output.flush()
    return removed
