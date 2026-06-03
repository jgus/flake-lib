#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix nixpkgs#gh nixpkgs#gnused nixpkgs#nix-prefetch-github nixpkgs#nix-prefetch-git nixpkgs#coreutils --command bash

# Generic update-version for jgus sub-flakes, driven by env vars injected by flake-lib's mkUpdateVersion:
#   SOURCE_TYPE   pypi | github | gitlab
#   PYPI_NAME     PyPI distribution name (underscore form)   [pypi]
#   PYPI_FORMAT   sdist | wheel                              [pypi]
#   GH_OWNER/GH_REPO          GitHub owner/repo              [github]
#   GITLAB_OWNER/GITLAB_REPO  GitLab owner/repo              [gitlab]
#   BUILD_ATTR    flake package attr to build-verify
#   SIBLINGS      JSON array of sibling-cascade specs (may be [])
#   CASCADE_PY    path to cascade.py (python3+packaging supplied via runtimeInputs)
#
# Pins pin.nix (and, for cascades, the sibling URLs in flake.nix) to a specific or latest
# upstream release, re-validating every hash. Idempotent: a no-op when nothing changed.
#
#   nix run .#update-version            # latest upstream
#   nix run .#update-version -- X.Y.Z   # specific version / ref
#
# Run from the flake root (or set FLAKE_ROOT).

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
pin="${FLAKE_ROOT}/pin.nix"
flake="${FLAKE_ROOT}/flake.nix"

if [[ ! -f "${pin}" ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  exit 1
fi

requested="${1:-}"
pin_changed=0
new_version=""

fetch_repo_file() {
  # $1 = path in repo, $2 = rev. Echoes file contents on stdout.
  local path="$1" rev="$2" proj enc
  case "${SOURCE_TYPE}" in
    github)
      gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/${path}?ref=${rev}" --jq '.content' | base64 -d
      ;;
    gitlab)
      proj="${GITLAB_OWNER}%2F${GITLAB_REPO}"
      enc=$(jq -rn --arg p "${path}" '$p|@uri')
      curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/files/${enc}/raw?ref=${rev}"
      ;;
  esac
}

resolve_and_rewrite_siblings() {
  # $1 = source rev to read requirements at. Rewrites flake.nix sibling URLs in place.
  local rev="$1" n i reqName pypiName flakeRepo mode reqFile spec ref req_text
  n=$(jq 'length' <<<"${SIBLINGS}")
  for (( i = 0; i < n; i++ )); do
    reqName=$(jq -r ".[$i].reqName" <<<"${SIBLINGS}")
    pypiName=$(jq -r ".[$i].pypiName // \"\"" <<<"${SIBLINGS}")
    flakeRepo=$(jq -r ".[$i].flakeRepo" <<<"${SIBLINGS}")
    mode=$(jq -r ".[$i].mode // \"resolve\"" <<<"${SIBLINGS}")
    reqFile=$(jq -r ".[$i].reqFile // \"requirements.txt\"" <<<"${SIBLINGS}")
    req_text=$(fetch_repo_file "${reqFile}" "${rev}" || true)
    if [[ -z "${req_text}" ]]; then
      echo "warning: could not fetch ${reqFile} at ${rev}; ${flakeRepo} URL left unchanged." >&2
      continue
    fi
    spec=$(printf '%s\n' "${req_text}" | sed -nE "s/^${reqName}(\[[^]]*\])?[[:space:]]*([~<>=!].*)$/\2/p" | head -1)
    if [[ -z "${spec}" ]]; then
      echo "warning: no ${reqName} line in ${reqFile}; ${flakeRepo} URL left unchanged." >&2
      continue
    fi
    ref=$(python3 "${CASCADE_PY}" "${mode}" "${pypiName}" "${spec}" || true)
    if [[ -z "${ref}" ]]; then
      echo "warning: could not resolve ${reqName} '${spec}'; ${flakeRepo} URL left unchanged." >&2
      continue
    fi
    echo "  ${reqName} ${spec} -> github:${flakeRepo}/${ref}"
    sed -i -E "s|(url = \"github:${flakeRepo})(/[^\"]*)?(\")|\\1/${ref}\\3|" "${flake}"
  done
}

case "${SOURCE_TYPE}" in
  pypi)
    if [[ -n "${requested}" ]]; then
      new_version="${requested}"
    else
      new_version=$(curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" | jq -r '.info.version')
    fi
    cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
    cur_hash=$(nix eval --raw --file "${pin}" hash 2>/dev/null || echo "")
    echo "Resolving ${PYPI_NAME} ${new_version} on PyPI..."
    rel=$(curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/${new_version}/json")
    if [[ "${PYPI_FORMAT}" == "wheel" ]]; then
      url=$(jq -r '[.urls[] | select(.packagetype == "bdist_wheel")][0].url' <<<"${rel}")
    else
      url=$(jq -r '[.urls[] | select(.packagetype == "sdist")][0].url' <<<"${rel}")
    fi
    if [[ -z "${url}" || "${url}" == "null" ]]; then
      echo "error: no ${PYPI_FORMAT} artifact for ${PYPI_NAME} ${new_version}" >&2
      exit 1
    fi
    new_hash=$(nix store prefetch-file --json --hash-type sha256 "${url}" | jq -r '.hash')
    if [[ "${cur_version}" == "${new_version}" && "${cur_hash}" == "${new_hash}" ]]; then
      echo "Already up to date (${cur_version})."
      exit 0
    fi
    echo "Writing pin.nix (${cur_version:-<none>} -> ${new_version})..."
    cat > "${pin}" <<EOF
{
  version = "${new_version}";
  hash = "${new_hash}";
}
EOF
    pin_changed=1
    ;;

  github)
    if [[ -n "${requested}" ]]; then
      new_version="${requested#[Vv]}"
    else
      echo "Querying GitHub for latest release of ${GH_OWNER}/${GH_REPO}..."
      new_version=$(gh api "/repos/${GH_OWNER}/${GH_REPO}/releases/latest" --jq '.tag_name')
      new_version="${new_version#[Vv]}"
    fi
    new_rev=""
    for candidate in "v${new_version}" "V${new_version}" "${new_version}"; do
      if sha=$(gh api "/repos/${GH_OWNER}/${GH_REPO}/commits/${candidate}" --jq '.sha' 2>/dev/null); then
        new_rev="${sha}"
        break
      fi
    done
    if [[ -z "${new_rev}" ]]; then
      echo "error: could not resolve v${new_version} / V${new_version} / ${new_version} on ${GH_OWNER}/${GH_REPO}" >&2
      exit 1
    fi
    cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
    cur_rev=$(nix eval --raw --file "${pin}" sourceRev 2>/dev/null || echo "")
    cur_hash=$(nix eval --raw --file "${pin}" sourceHash 2>/dev/null || echo "")
    echo "Computing source hash for ${GH_OWNER}/${GH_REPO}@${new_rev}..."
    new_hash=$(nix-prefetch-github --rev "${new_rev}" "${GH_OWNER}" "${GH_REPO}" --json | jq -r '.hash // .sha256')
    if [[ "${cur_version}" != "${new_version}" || "${cur_rev}" != "${new_rev}" || "${cur_hash}" != "${new_hash}" ]]; then
      pin_changed=1
      echo "Writing pin.nix (${cur_version:-<none>} -> ${new_version})..."
      cat > "${pin}" <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${new_version}";
  sourceRev = "${new_rev}";
  sourceHash = "${new_hash}";
}
EOF
    fi
    if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
      echo "Resolving sibling cascades..."
      resolve_and_rewrite_siblings "${new_rev}"
    fi
    ;;

  gitlab)
    proj="${GITLAB_OWNER}%2F${GITLAB_REPO}"
    if [[ -n "${requested}" ]]; then
      commit=$(curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/commits/${requested}")
    else
      echo "Querying GitLab for latest master commit of ${GITLAB_OWNER}/${GITLAB_REPO}..."
      commit=$(curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/branches/master" | jq -r '.commit')
    fi
    new_rev=$(jq -r '.id' <<<"${commit}")
    new_date=$(jq -r '.committed_date' <<<"${commit}" | cut -d'T' -f1)
    new_version="0-unstable-${new_date}"
    cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
    cur_rev=$(nix eval --raw --file "${pin}" sourceRev 2>/dev/null || echo "")
    cur_hash=$(nix eval --raw --file "${pin}" sourceHash 2>/dev/null || echo "")
    echo "Computing source hash for ${GITLAB_OWNER}/${GITLAB_REPO}@${new_rev}..."
    new_hash=$(nix-prefetch-git --quiet --url "https://gitlab.com/${GITLAB_OWNER}/${GITLAB_REPO}.git" --rev "${new_rev}" | jq -r '.hash')
    if [[ "${cur_version}" != "${new_version}" || "${cur_rev}" != "${new_rev}" || "${cur_hash}" != "${new_hash}" ]]; then
      pin_changed=1
      echo "Writing pin.nix (${cur_version:-<none>} -> ${new_version})..."
      cat > "${pin}" <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${new_version}";
  sourceRev = "${new_rev}";
  sourceHash = "${new_hash}";
}
EOF
    fi
    if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
      echo "Resolving sibling cascades..."
      resolve_and_rewrite_siblings "${new_rev}"
    fi
    ;;

  *)
    echo "error: unknown SOURCE_TYPE=${SOURCE_TYPE}" >&2
    exit 1
    ;;
esac

echo "Verifying build (${BUILD_ATTR})..."
nix build --option post-build-hook "" "${FLAKE_ROOT}#${BUILD_ATTR}" --no-link

echo
if (( pin_changed )); then
  echo "Updated ${BUILD_ATTR} to ${new_version}."
else
  echo "${BUILD_ATTR}: pin unchanged (${new_version})."
fi
echo "  Commit pin.nix / flake.nix / flake.lock to capture."
