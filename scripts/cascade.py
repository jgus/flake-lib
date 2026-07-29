"""Resolve a sibling -flake aggregate/exact branch ref from an upstream requirement spec.

Usage: cascade.py <mode> <pypiName> <spec>
  mode "exact"   : spec is an exact pin (==X.Y.Z); print vX.Y.Z without querying PyPI.
  mode "resolve" : query PyPI for the highest non-pre release satisfying spec; print vX.Y.Z for an == constraint, otherwise the vX.Y aggregate.

Prints nothing (exit 0) when it can't resolve, so the caller leaves the URL unchanged.
"""

import http.client
import json
import sys
import time
import urllib.error
import urllib.request

from packaging.specifiers import SpecifierSet
from packaging.version import InvalidVersion, Version

RETRY_ATTEMPTS = 5
RETRY_DELAY_S = 5


def is_transient(status: int) -> bool:
    return status >= 500 or status == 429


def fetch_pypi_metadata(name: str) -> dict:
    for attempt in range(1, RETRY_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/json", timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            if not is_transient(e.code) or attempt == RETRY_ATTEMPTS:
                raise
        except (OSError, http.client.IncompleteRead):
            if attempt == RETRY_ATTEMPTS:
                raise
        time.sleep(RETRY_DELAY_S)
    raise RuntimeError("unreachable")


mode, pypi_name, spec_str = sys.argv[1], sys.argv[2], sys.argv[3]
spec = SpecifierSet(spec_str)

if mode == "exact":
    exacts = [s.version for s in spec if s.operator in ("==", "===")]
    if exacts:
        print(f"v{exacts[0]}")
    sys.exit(0)

data = fetch_pypi_metadata(pypi_name)
candidates = []
for raw in data["releases"]:
    try:
        v = Version(raw)
    except InvalidVersion:
        continue
    if v.is_prerelease or v.is_devrelease:
        continue
    if v in spec:
        candidates.append(v)

if not candidates:
    sys.exit(0)

top = max(candidates)
if any(s.operator == "==" for s in spec):
    print(f"v{top.public}")
else:
    print(f"v{top.major}.{top.minor}")
