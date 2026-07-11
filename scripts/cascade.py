"""Resolve a sibling -flake aggregate/exact branch ref from an upstream requirement spec.

Usage: cascade.py <mode> <pypiName> <spec>
  mode "exact"   : spec is an exact pin (==X.Y.Z); print vX.Y.Z without querying PyPI.
  mode "resolve" : query PyPI for the highest non-pre release satisfying spec; print vX.Y.Z for an == constraint, otherwise the vX.Y aggregate.

Prints nothing (exit 0) when it can't resolve, so the caller leaves the URL unchanged.
"""

import json
import sys
import urllib.request

from packaging.specifiers import SpecifierSet
from packaging.version import InvalidVersion, Version

mode, pypi_name, spec_str = sys.argv[1], sys.argv[2], sys.argv[3]
spec = SpecifierSet(spec_str)

if mode == "exact":
    exacts = [s.version for s in spec if s.operator in ("==", "===")]
    if exacts:
        print(f"v{exacts[0]}")
    sys.exit(0)

data = json.loads(urllib.request.urlopen(f"https://pypi.org/pypi/{pypi_name}/json").read())
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
