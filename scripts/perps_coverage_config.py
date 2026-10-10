"""Normalize coverage remappings for Solar's dependency source resolver."""

import json
import sys
from pathlib import Path


def absolute_remappings(remappings, package_root):
    normalized = []
    for remapping in remappings:
        prefix, separator, target = remapping.partition("=")
        if not separator or not target:
            raise ValueError(f"invalid coverage remapping: {remapping}")
        path = Path(target)
        if not path.is_absolute():
            path = package_root / path
        absolute = path.resolve().as_posix()
        if target.endswith("/"):
            absolute = absolute.rstrip("/") + "/"
        normalized.append(prefix + "=" + absolute)
    return normalized


if __name__ == "__main__":
    configuration = json.loads(Path(sys.argv[1]).read_text())
    print("\n".join(absolute_remappings(configuration["remappings"], Path(sys.argv[2]))))
