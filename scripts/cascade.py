import http.client
import json
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Iterable, Mapping
from typing import Any

from packaging.markers import default_environment
from packaging.requirements import InvalidRequirement, Requirement
from packaging.specifiers import SpecifierSet
from packaging.utils import canonicalize_name
from packaging.version import InvalidVersion, Version

RETRY_ATTEMPTS = 5
RETRY_DELAY_S = 5


def is_transient(status: int) -> bool:
    return status >= 500 or status == 429


def fetch_pypi_metadata(name: str) -> dict[str, Any]:
    for attempt in range(1, RETRY_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(
                f"https://pypi.org/pypi/{name}/json", timeout=60
            ) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if not is_transient(error.code) or attempt == RETRY_ATTEMPTS:
                raise
        except (OSError, http.client.IncompleteRead):
            if attempt == RETRY_ATTEMPTS:
                raise
        time.sleep(RETRY_DELAY_S)
    raise RuntimeError("unreachable")


def exact_version(specifiers: SpecifierSet) -> Version | None:
    candidates = [
        specifier.version
        for specifier in specifiers
        if specifier.operator in {"==", "==="} and "*" not in specifier.version
    ]
    if len(candidates) != 1:
        return None
    try:
        version = Version(candidates[0])
    except InvalidVersion:
        return None
    return version if specifiers.contains(version, prereleases=True) else None


def is_unbounded_minimum(specifiers: SpecifierSet) -> bool:
    return all(specifier.operator in {">", ">="} for specifier in specifiers)


def resolve_ref(
    mode: str,
    pypi_name: str,
    specifiers: SpecifierSet,
    releases: Iterable[str] | None = None,
) -> str | None:
    exact = exact_version(specifiers)
    if exact is not None:
        return f"v{exact.public}"
    if mode == "exact":
        return None
    if mode != "resolve":
        raise ValueError(f"unknown cascade mode: {mode}")
    if is_unbounded_minimum(specifiers):
        return "main"

    if releases is None:
        releases = fetch_pypi_metadata(pypi_name)["releases"]

    candidates = []
    for raw_version in releases:
        try:
            version = Version(raw_version)
        except InvalidVersion:
            continue
        if version.is_prerelease or version.is_devrelease:
            continue
        if specifiers.contains(version):
            candidates.append(version)

    if not candidates:
        return None

    latest = max(candidates)
    return f"v{latest.major}.{latest.minor}"


def requirement_specifiers(
    metadata: Mapping[str, Any],
    requirement_name: str,
    environment: Mapping[str, str] | None = None,
) -> SpecifierSet | None:
    marker_environment = dict(
        default_environment() if environment is None else environment
    )
    marker_environment.setdefault("extra", "")
    normalized_name = canonicalize_name(requirement_name)
    matched = []

    for raw_requirement in metadata.get("info", {}).get("requires_dist") or []:
        try:
            requirement = Requirement(raw_requirement)
        except InvalidRequirement:
            continue
        if canonicalize_name(requirement.name) != normalized_name:
            continue
        if requirement.marker is not None and not requirement.marker.evaluate(
            marker_environment
        ):
            continue
        matched.append(str(requirement.specifier))

    if not matched:
        return None
    return SpecifierSet(",".join(filter(None, matched)))


def resolve_metadata_ref(
    metadata: Mapping[str, Any],
    requirement_name: str,
    pypi_name: str,
    mode: str,
    environment: Mapping[str, str] | None = None,
) -> str | None:
    specifiers = requirement_specifiers(metadata, requirement_name, environment)
    if specifiers is None:
        return None
    return resolve_ref(mode, pypi_name or requirement_name, specifiers)


def sorted_versions(
    raw_versions: Iterable[str],
    minimum: str,
    stable_only: bool = False,
) -> list[str]:
    minimum_version = Version(minimum)
    versions = []
    for raw_version in raw_versions:
        raw_version = raw_version.strip()
        try:
            version = Version(raw_version)
        except InvalidVersion:
            continue
        if version < minimum_version:
            continue
        if stable_only and (version.is_prerelease or version.is_devrelease):
            continue
        versions.append((version, raw_version))
    return [raw_version for _, raw_version in sorted(versions)]


def main(arguments: list[str]) -> None:
    command = arguments[1]
    if command in {"exact", "resolve"}:
        ref = resolve_ref(command, arguments[2], SpecifierSet(arguments[3]))
        if ref is not None:
            print(ref)
        return
    if command == "metadata":
        ref = resolve_metadata_ref(
            json.load(sys.stdin), arguments[2], arguments[3], arguments[4]
        )
        if ref is not None:
            print(ref)
        return
    if command == "sort":
        stable_only = len(arguments) > 3 and arguments[3] == "stable"
        for version in sorted_versions(sys.stdin, arguments[2], stable_only):
            print(version)
        return
    raise ValueError(f"unknown command: {command}")


if __name__ == "__main__":
    main(sys.argv)
