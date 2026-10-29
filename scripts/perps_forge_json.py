"""Stream Forge JSON without retaining successful execution traces in memory.

Foundry 1.5.1's --suppress-successful-traces affects display, but its JSON still
contains successful invariant traces. Preserve all failure evidence and metrics.
"""

import json
import re

TOKEN = re.compile(r'"[^"\\]*(?:\\.[^"\\]*)*"|[{}\[\]:,]|[^\s{}\[\]:,"]+')
SPACE = re.compile(r"\s+")
STRUCTURE = re.compile(r'"|\\.|\\$|[{}\[\]]', re.S)


class Tokens:
    def __init__(self, source, first="", chunk_size=65536):
        self.source, self.buffer, self.chunk_size = source, first, chunk_size
        self.position, self.eof = 0, False

    def __iter__(self):
        return self

    def __next__(self):
        while True:
            whitespace = SPACE.match(self.buffer, self.position)
            if whitespace:
                self.position = whitespace.end()
            if self.position == len(self.buffer):
                if self.eof:
                    raise StopIteration
                self.buffer, self.position = self.source.read(self.chunk_size), 0
                self.eof = not self.buffer
                continue
            match = TOKEN.match(self.buffer, self.position)
            # Scalars and strings split across read boundaries must be completed.
            if match and (match.end() < len(self.buffer) or self.eof or match.group()[-1:] in '{}[]:,"'):
                self.position = match.end()
                return match.group()
            if self.eof:
                raise ValueError("incomplete JSON token")
            more = self.source.read(self.chunk_size)
            self.buffer = self.buffer[self.position:] + more
            self.position = 0
            self.eof = not more

    def skip_value(self):
        """Discard successful traces a chunk at a time, without tokenizing bytecode.

        Setup/deployment traces repeat very large bytecode strings. Parsing each
        one into a token repeatedly rescans partial strings at chunk boundaries.
        Only nesting, quotes and escapes matter while discarding this value.
        """
        first = next(self)
        if first not in ("[", "{"):
            return
        depth, in_string, escaped = 1, False, False
        while True:
            if escaped and self.position < len(self.buffer):
                self.position += 1
                escaped = False
            for match in STRUCTURE.finditer(self.buffer, self.position):
                marker = match.group()
                if marker == '"':
                    in_string = not in_string
                elif in_string:
                    escaped = marker == "\\"
                elif marker in ("[", "{"):
                    depth += 1
                elif marker in ("]", "}"):
                    depth -= 1
                    if depth == 0:
                        self.position = match.end()
                        return
            self.buffer, self.position = self.source.read(self.chunk_size), 0
            if not self.buffer:
                raise ValueError("incomplete JSON trace value")


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
    iterator = iter(Tokens(source, first, chunk_size))
    removed = 0

    def take():
        try:
            return next(iterator)
        except StopIteration as error:
            raise ValueError("incomplete JSON document") from error

    def emit(token):
        output.write(redact(token))

    def skip_value():
        try:
            iterator.skip_value()
        except StopIteration as error:
            raise ValueError("incomplete JSON document") from error

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
