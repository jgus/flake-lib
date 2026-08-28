#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix nixpkgs#gh nixpkgs#gnused nixpkgs#nix-prefetch-github nixpkgs#nix-prefetch-git nixpkgs#coreutils --command bash

# Generic update-version for jgus sub-flakes, driven by env vars injected by flake-lib's mkUpdateVersion:
#   SOURCE_TYPE   pypi | github | github-release-asset | gitlab | huggingface
#   PYPI_NAME     PyPI distribution name (underscore form)   [pypi]
#   PYPI_FORMAT   sdist | wheel                              [pypi]
#   GH_OWNER/GH_REPO          GitHub owner/repo              [github, github-release-asset]
#   GH_TRACK                  release (Releases API) | tag (latest version git tag) | commit (default-branch HEAD -> 0-unstable-DATE)  [github]
#   GH_BRANCH                 commit-tracking: branch to follow (default: repo default branch)  [github]
#   GH_ASSET                  release-asset filename template; tokens ${version} (tag minus leading v) and ${tag}  [github-release-asset]
#   GH_TAG                    release-tag template; token ${version} (default: v${version})  [github-release-asset]
#   GITLAB_OWNER/GITLAB_REPO  GitLab owner/repo              [gitlab]
#   GITLAB_TRACK              release (tags -> X.Y.Z) | commit (master HEAD -> 0-unstable-DATE)  [gitlab]
#   BUILD_ATTR    flake package attr to build-verify
#   SIBLINGS      JSON array of sibling-cascade specs (may be [])
#   CASCADE_PY    path to cascade.py (python3+packaging supplied via runtimeInputs)
#
# Pins pin.nix (and, for cascades, the sibling URLs in flake.nix) to a specific or latest upstream release, re-validating every hash. Idempotent: a no-op when nothing changed.
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
# Optional upstream ref to fetch, distinct from the version written to the pin. Lets the orchestrator pin a canonical version string (e.g. 0.1.40.5-beta) while still resolving the raw upstream tag (e.g. v0.1.405-beta). Defaults to `requested`, i.e. version == ref.
requested_ref="${2:-}"
pin_changed=0
new_version=""
CASCADE_CHANGED=0

# Optional seams (defaulted so simple pypi leaves need not set them):
HASH_MODE="${HASH_MODE:-prefetch}"        # prefetch | build-failure (source/vendor hash)
EXTRA_HASHES="${EXTRA_HASHES:-[]}"        # JSON array of extra pin field names (e.g. ["npmDepsHash"])
PIN_HASHES="${PIN_HASHES:-${EXTRA_HASHES}}"
BUILD_FAILURE_HASH="${BUILD_FAILURE_HASH:-}"
ARTIFACT_HOOK="${ARTIFACT_HOOK:-}"        # consumer script: regenerate vendored files, emit name=value extra hashes
SKIP_BUILD="${SKIP_BUILD:-}"              # non-empty: skip the final build verification (heavy builds)
SIBLINGS="${SIBLINGS:-[]}"
CASCADE_PY="${CASCADE_PY:-}"
GH_TRACK="${GH_TRACK:-release}"
GH_BRANCH="${GH_BRANCH:-}"
GH_FETCH_SUBMODULES="${GH_FETCH_SUBMODULES:-}"  # non-empty: hash the tree with submodules
GH_ASSET="${GH_ASSET:-}"
GH_TAG="${GH_TAG:-}"
GITLAB_TRACK="${GITLAB_TRACK:-commit}"
HF_REPO="${HF_REPO:-}"
HF_REVISION="${HF_REVISION:-main}"
HF_FILES="${HF_FILES:-[]}"

declare -A extra=()
declare -A HF_HASHES=()

# Buffers output and emits it only on success, so a consumer never sees partial data from an attempt that died mid-stream. The tag-spelling probes are wrapped at whole-sweep granularity (resolve_*_ref_sha) so an expected 404 on one candidate spelling is never individually retried.
retry() {
  local attempt output
  for attempt in 1 2 3 4 5; do
    if output=$("$@"); then
      [[ -z "${output}" ]] || printf '%s\n' "${output}"
      return 0
    fi
    if (( attempt < 5 )); then
      echo "  ${1} failed (attempt ${attempt}/5); retrying in 5s..." >&2
      sleep 5
    fi
  done
  echo "  ${1} failed after 5 attempts" >&2
  return 1
}

fetch_repo_file() {
  local path="$1" rev="$2" proj enc
  case "${SOURCE_TYPE}" in
    github)
      retry gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/${path}?ref=${rev}" --jq '.content' | base64 -d
      ;;
    gitlab)
      proj="${GITLAB_OWNER}%2F${GITLAB_REPO}"
      enc=$(jq -rn --arg p "${path}" '$p|@uri')
      retry curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/files/${enc}/raw?ref=${rev}"
      ;;
  esac
}

resolve_github_ref_sha() {
  local ref_base="$1" candidate sha
  for candidate in "v${ref_base}" "V${ref_base}" "${ref_base}"; do
    if sha=$(gh api "/repos/${GH_OWNER}/${GH_REPO}/commits/${candidate}" --jq '.sha' 2>/dev/null) && [[ -n "${sha}" ]]; then
      echo "${sha}"
      return 0
    fi
  done
  return 1
}

resolve_gitlab_ref_sha() {
  local proj="$1" ref_base="$2" candidate id
  for candidate in "v${ref_base}" "V${ref_base}" "${ref_base}"; do
    if id=$(curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/commits/${candidate}" 2>/dev/null | jq -r '.id // ""') && [[ -n "${id}" && "${id}" != "null" ]]; then
      echo "${id}"
      return 0
    fi
  done
  return 1
}

rewrite_sibling_url() {
  local FLAKE_REPO="${1}" REF="${2}" BEFORE AFTER
  BEFORE=$(sha256sum "${flake}")
  sed -i -E "s|(url = \"github:${FLAKE_REPO})(/[^\"]*)?(\")|\\1/${REF}\\3|" "${flake}"
  AFTER=$(sha256sum "${flake}")
  if [[ "${BEFORE}" != "${AFTER}" ]]; then
    CASCADE_CHANGED=1
  fi
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
    rewrite_sibling_url "${flakeRepo}" "${ref}"
  done
}

resolve_and_rewrite_pypi_siblings() {
  local METADATA="${1}" COUNT INDEX REQUIREMENT_NAME PYPI_NAME FLAKE_REPO MODE REF
  COUNT=$(jq 'length' <<<"${SIBLINGS}")
  for (( INDEX = 0; INDEX < COUNT; INDEX++ )); do
    REQUIREMENT_NAME=$(jq -r ".[${INDEX}].reqName" <<<"${SIBLINGS}")
    PYPI_NAME=$(jq -r ".[${INDEX}].pypiName // \"\"" <<<"${SIBLINGS}")
    FLAKE_REPO=$(jq -r ".[${INDEX}].flakeRepo" <<<"${SIBLINGS}")
    MODE=$(jq -r ".[${INDEX}].mode // \"resolve\"" <<<"${SIBLINGS}")
    REF=$(python3 "${CASCADE_PY}" metadata "${REQUIREMENT_NAME}" "${PYPI_NAME}" "${MODE}" <<<"${METADATA}" || true)
    if [[ -z "${REF}" ]]; then
      echo "warning: no applicable ${REQUIREMENT_NAME} requirement could be resolved; ${FLAKE_REPO} URL left unchanged." >&2
      continue
    fi
    echo "  ${REQUIREMENT_NAME} -> github:${FLAKE_REPO}/${REF}"
    rewrite_sibling_url "${FLAKE_REPO}" "${REF}"
  done
}

write_source_pin() {
  local v="$1" rev="$2" h="$3" name
  {
    echo "# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump."
    echo "{"
    echo "  version = \"${v}\";"
    echo "  sourceRev = \"${rev}\";"
    echo "  sourceHash = \"${h}\";"
    for name in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
      echo "  ${name} = \"${extra[${name}]:-}\";"
    done
    echo "}"
  } > "${pin}"
}

write_huggingface_pin() {
  local VERSION="${1}" REV="${2}" FILE FILE_LITERAL HASH_LITERAL
  {
    echo "{"
    echo "  version = \"${VERSION}\";"
    echo "  sourceRev = \"${REV}\";"
    if [[ "$(jq 'length' <<<"${HF_FILES}")" -gt 0 ]]; then
      echo "  hashes = {"
      while IFS= read -r FILE; do
        FILE_LITERAL=$(jq -Rn --arg VALUE "${FILE}" '$VALUE')
        HASH_LITERAL=$(jq -Rn --arg VALUE "${HF_HASHES[${FILE}]}" '$VALUE')
        printf '    %s = %s;\n' "${FILE_LITERAL}" "${HASH_LITERAL}"
      done < <(jq -r '.[]' <<<"${HF_FILES}")
      echo "  };"
    fi
    echo "}"
  } > "${pin}"
}

huggingface_pin_current() {
  local VERSION="${1}" REV="${2}" CURRENT_VERSION CURRENT_REV CURRENT_HASHES CURRENT_FILES EXPECTED_FILES FILE HASH
  CURRENT_VERSION=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
  CURRENT_REV=$(nix eval --raw --file "${pin}" sourceRev 2>/dev/null || echo "")
  [[ "${CURRENT_VERSION}" == "${VERSION}" && "${CURRENT_REV}" == "${REV}" ]] || return 1
  CURRENT_HASHES=$(nix eval --json --file "${pin}" hashes 2>/dev/null || echo '{}')
  CURRENT_FILES=$(jq -c 'keys | sort' <<<"${CURRENT_HASHES}")
  EXPECTED_FILES=$(jq -c 'sort' <<<"${HF_FILES}")
  [[ "${CURRENT_FILES}" == "${EXPECTED_FILES}" ]] || return 1
  while IFS= read -r FILE; do
    HASH=$(jq -r --arg FILE "${FILE}" '.[$FILE] // ""' <<<"${CURRENT_HASHES}")
    [[ -n "${HASH}" ]] || return 1
  done < <(jq -r '.[]' <<<"${HF_FILES}")
  return 0
}

run_artifact_hook() {
  # $1 rev, $2 version. Runs the consumer hook (which regenerates vendored files in FLAKE_ROOT) and captures its `name=value` stdout lines into `extra`.
  local rev="$1" v="$2" hook_out k val
  [[ -z "${ARTIFACT_HOOK}" ]] && return 0
  echo "Running artifact hook..."
  hook_out=$(NEW_REV="${rev}" NEW_VERSION="${v}" FLAKE_ROOT="${FLAKE_ROOT}" \
    GH_OWNER="${GH_OWNER}" GH_REPO="${GH_REPO}" \
    GITLAB_OWNER="${GITLAB_OWNER}" GITLAB_REPO="${GITLAB_REPO}" "${ARTIFACT_HOOK}")
  while IFS= read -r line; do
    # Split on the first '=' only, so a base64 SRI's trailing '=' padding survives.
    k="${line%%=*}"
    [[ -n "${k}" ]] && extra["${k}"]="${line#*=}"
  done <<<"${hook_out}"
  return 0 # the loop's status is its last body command — a falsy `[[ -n ]]` on an empty/keyless line — which would trip the caller's set -e; this function has no meaningful return
}

revalidate_hash() {
  # $1 = pin field. Build; on a fixed-output hash mismatch, rewrite the field from nix's "got:" and rebuild. For vendor hashes that can't be prefetched.
  local field="$1" out rc new
  echo "Validating ${field} via build..."
  set +e
  out=$(nix build --option post-build-hook "" "${FLAKE_ROOT}#${BUILD_ATTR}" --no-link 2>&1)
  rc=$?
  set -e
  (( rc == 0 )) && return 0
  new=$(printf '%s\n' "${out}" | sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/p' | head -1)
  if [[ -z "${new}" ]]; then
    echo "error: build of ${BUILD_ATTR} failed and it wasn't a hash mismatch:" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  fi
  echo "  ${field} drift -> ${new}"
  sed -i -E "s|^([[:space:]]*${field}[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${new}\\2|" "${pin}"
}

source_pin_current() {
  # $1 version, $2 rev. True (0) when pin.nix already matches at this version+rev with sourceHash and every EXTRA_HASHES field populated. Lets a no-op run skip the artifactHook + cascade regeneration (which can be non-deterministic, e.g. npm lockfiles) instead of churning the pin on every run. A placeholder pin (empty hash) returns false, so the populate path still runs; callers skip this in build-failure mode, where the hash can drift without a rev change.
  local v="$1" rev="$2" cv crev csh name val
  cv=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
  crev=$(nix eval --raw --file "${pin}" sourceRev 2>/dev/null || echo "")
  csh=$(nix eval --raw --file "${pin}" sourceHash 2>/dev/null || echo "")
  [[ "${cv}" == "${v}" && "${crev}" == "${rev}" && -n "${csh}" ]] || return 1
  for name in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
    val=$(nix eval --raw --file "${pin}" "${name}" 2>/dev/null || echo "")
    [[ -n "${val}" ]] || return 1
  done
  return 0
}

case "${SOURCE_TYPE}" in
  pypi)
    if [[ -n "${requested}" ]]; then
      new_version="${requested}"
    else
      new_version=$(retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" | jq -r '.info.version')
    fi
    cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
    cur_hash=$(nix eval --raw --file "${pin}" hash 2>/dev/null || echo "")
    echo "Resolving ${PYPI_NAME} ${new_version} on PyPI..."
    rel=$(retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/${new_version}/json")
    if [[ "${PYPI_FORMAT}" == "wheel" ]]; then
      # Prefer the universal py3-none-any wheel (what mk-pypi-package fetches); fall back to the first wheel.
      url=$(jq -r '([.urls[] | select(.packagetype == "bdist_wheel") | select(.filename | endswith("-py3-none-any.whl"))][0].url) // ([.urls[] | select(.packagetype == "bdist_wheel")][0].url)' <<<"${rel}")
    else
      url=$(jq -r '[.urls[] | select(.packagetype == "sdist")][0].url' <<<"${rel}")
    fi
    if [[ -z "${url}" || "${url}" == "null" ]]; then
      echo "error: no ${PYPI_FORMAT} artifact for ${PYPI_NAME} ${new_version}" >&2
      exit 1
    fi
    new_hash=$(nix store prefetch-file --json --hash-type sha256 "${url}" | jq -r '.hash')
    if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
      echo "Resolving sibling cascades..."
      resolve_and_rewrite_pypi_siblings "${rel}"
    fi
    if [[ "${cur_version}" == "${new_version}" && "${cur_hash}" == "${new_hash}" ]]; then
      if (( CASCADE_CHANGED == 0 )); then
        echo "Already up to date (${cur_version})."
        exit 0
      fi
      echo "Source pin already up to date (${cur_version})."
    else
      echo "Writing pin.nix (${cur_version:-<none>} -> ${new_version})..."
      cat > "${pin}" <<EOF
{
  version = "${new_version}";
  hash = "${new_hash}";
}
EOF
      pin_changed=1
    fi
    ;;

  github)
    if [[ "${GH_TRACK}" == "commit" ]]; then
      if [[ -n "${requested}" ]]; then
        commit=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/commits/${requested}")
      else
        branch="${GH_BRANCH:-$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}" --jq '.default_branch')}"
        echo "Querying GitHub for latest commit on ${GH_OWNER}/${GH_REPO}@${branch}..."
        commit=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/commits/${branch}")
      fi
      new_rev=$(jq -r '.sha' <<<"${commit}")
      new_version="0-unstable-$(jq -r '.commit.committer.date' <<<"${commit}" | cut -d'T' -f1)"
    else
      if [[ -n "${requested}" ]]; then
        new_version="${requested#[Vv]}"
      elif [[ "${GH_TRACK}" == "tag" ]]; then
        echo "Querying GitHub for latest tag of ${GH_OWNER}/${GH_REPO}..."
        new_version=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/tags" --jq '[.[].name | select(test("^[vV]?[0-9]"))][0] // ""')
        new_version="${new_version#[Vv]}"
        if [[ -z "${new_version}" ]]; then
          echo "error: could not determine a version tag for ${GH_OWNER}/${GH_REPO}" >&2
          exit 1
        fi
      else
        echo "Querying GitHub for latest release of ${GH_OWNER}/${GH_REPO}..."
        new_version=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/releases/latest" --jq '.tag_name')
        new_version="${new_version#[Vv]}"
      fi
      ref_base="${requested_ref:-${new_version}}"
      ref_base="${ref_base#[Vv]}"
      new_rev=$(retry resolve_github_ref_sha "${ref_base}" || true)
      if [[ -z "${new_rev}" ]]; then
        echo "error: could not resolve v${ref_base} / V${ref_base} / ${ref_base} on ${GH_OWNER}/${GH_REPO}" >&2
        exit 1
      fi
    fi
    if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
      echo "Resolving sibling cascades..."
      resolve_and_rewrite_siblings "${new_rev}"
    fi
    if [[ "${HASH_MODE}" != "build-failure" ]] && source_pin_current "${new_version}" "${new_rev}" && (( CASCADE_CHANGED == 0 )); then
      echo "Already up to date (${new_version})."
      exit 0
    fi
    run_artifact_hook "${new_rev}" "${new_version}"
    if [[ "${HASH_MODE}" == "build-failure" ]]; then
      new_hash=""
    else
      echo "Computing source hash for ${GH_OWNER}/${GH_REPO}@${new_rev}..."
      new_hash=$(nix-prefetch-github ${GH_FETCH_SUBMODULES:+--fetch-submodules} --rev "${new_rev}" "${GH_OWNER}" "${GH_REPO}" --json | jq -r '.hash // .sha256')
    fi
    echo "Writing pin.nix (-> ${new_version})..."
    write_source_pin "${new_version}" "${new_rev}" "${new_hash}"
    pin_changed=1
    if [[ -n "${BUILD_FAILURE_HASH}" ]]; then
      revalidate_hash "${BUILD_FAILURE_HASH}"
    fi
    ;;

  github-release-asset)
    # A prebuilt release asset (single file), not the source tree: resolve the version like `github` (latest release tag, or the requested version), then prefetch-file the asset URL into a { version, hash } pin. No sourceRev — there is no tree to hash. Release assets are immutable, so a matching populated pin short-circuits before the (potentially large) download.
    if [[ -z "${GH_ASSET}" ]]; then
      echo "error: github-release-asset requires source.asset (GH_ASSET)" >&2
      exit 1
    fi
    if [[ -n "${requested}" ]]; then
      new_version="${requested#[Vv]}"
    else
      echo "Querying GitHub for latest release of ${GH_OWNER}/${GH_REPO}..."
      new_version=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/releases/latest" --jq '.tag_name')
      new_version="${new_version#[Vv]}"
    fi
    cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
    cur_hash=$(nix eval --raw --file "${pin}" hash 2>/dev/null || echo "")
    if [[ "${cur_version}" == "${new_version}" && -n "${cur_hash}" ]]; then
      echo "Already up to date (${new_version})."
      exit 0
    fi
    tag_tmpl="${GH_TAG}"
    [[ -n "${tag_tmpl}" ]] || tag_tmpl='v${version}'
    tag="${tag_tmpl//'${version}'/${new_version}}"
    asset="${GH_ASSET//'${version}'/${new_version}}"
    asset="${asset//'${tag}'/${tag}}"
    url="https://github.com/${GH_OWNER}/${GH_REPO}/releases/download/${tag}/${asset}"
    echo "Prefetching ${url}..."
    new_hash=$(nix store prefetch-file --json --hash-type sha256 "${url}" | jq -r '.hash')
    echo "Writing pin.nix (${cur_version:-<none>} -> ${new_version})..."
    cat > "${pin}" <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${new_version}";
  hash = "${new_hash}";
}
EOF
    pin_changed=1
    ;;

  huggingface)
    if [[ -z "${HF_REPO}" ]]; then
      echo "error: huggingface requires source.repo (HF_REPO)" >&2
      exit 1
    fi
    HF_REF="${requested:-${HF_REVISION}}"
    echo "Querying Hugging Face for ${HF_REPO}@${HF_REF}..."
    HF_METADATA=$(retry curl -sSfL "https://huggingface.co/api/models/${HF_REPO}/revision/${HF_REF}")
    HF_REV=$(jq -r '.sha // ""' <<<"${HF_METADATA}")
    HF_DATE=$(jq -r '.lastModified // ""' <<<"${HF_METADATA}" | cut -d'T' -f1)
    if [[ -z "${HF_REV}" || -z "${HF_DATE}" || "${HF_REV}" == "null" || "${HF_DATE}" == "null" ]]; then
      echo "error: could not resolve ${HF_REPO}@${HF_REF}" >&2
      exit 1
    fi
    new_version="0-unstable-${HF_DATE}"
    if huggingface_pin_current "${new_version}" "${HF_REV}"; then
      echo "Already up to date (${new_version})."
      exit 0
    fi
    while IFS= read -r HF_FILE; do
      HF_FILE_URL=$(jq -rn --arg VALUE "${HF_FILE}" '$VALUE | split("/") | map(@uri) | join("/")')
      echo "Prefetching ${HF_FILE}..."
      HF_HASHES["${HF_FILE}"]=$(nix store prefetch-file --json --hash-type sha256 "https://huggingface.co/${HF_REPO}/resolve/${HF_REV}/${HF_FILE_URL}" | jq -r '.hash')
    done < <(jq -r '.[]' <<<"${HF_FILES}")
    echo "Writing pin.nix (-> ${new_version})..."
    write_huggingface_pin "${new_version}" "${HF_REV}"
    pin_changed=1
    ;;

  gitlab)
    proj="${GITLAB_OWNER}%2F${GITLAB_REPO}"
    if [[ "${GITLAB_TRACK}" == "release" ]]; then
      if [[ -n "${requested}" ]]; then
        new_version="${requested#[Vv]}"
      else
        echo "Querying GitLab for latest tag of ${GITLAB_OWNER}/${GITLAB_REPO}..."
        new_version=$(retry curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/tags" | jq -r '[.[].name | select(test("^[vV]?[0-9]"))][0] // ""')
        new_version="${new_version#[Vv]}"
      fi
      if [[ -z "${new_version}" ]]; then
        echo "error: could not determine a release tag for ${GITLAB_OWNER}/${GITLAB_REPO}" >&2
        exit 1
      fi
      ref_base="${requested_ref:-${new_version}}"
      ref_base="${ref_base#[Vv]}"
      new_rev=$(retry resolve_gitlab_ref_sha "${proj}" "${ref_base}" || true)
      if [[ -z "${new_rev}" ]]; then
        echo "error: could not resolve v${ref_base} / V${ref_base} / ${ref_base} on ${GITLAB_OWNER}/${GITLAB_REPO}" >&2
        exit 1
      fi
    else
      if [[ -n "${requested}" ]]; then
        commit=$(retry curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/commits/${requested}")
      else
        echo "Querying GitLab for latest master commit of ${GITLAB_OWNER}/${GITLAB_REPO}..."
        commit=$(retry curl -sSfL "https://gitlab.com/api/v4/projects/${proj}/repository/branches/master" | jq -r '.commit')
      fi
      new_rev=$(jq -r '.id' <<<"${commit}")
      new_date=$(jq -r '.committed_date' <<<"${commit}" | cut -d'T' -f1)
      new_version="0-unstable-${new_date}"
    fi
    if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
      echo "Resolving sibling cascades..."
      resolve_and_rewrite_siblings "${new_rev}"
    fi
    if [[ "${HASH_MODE}" != "build-failure" ]] && source_pin_current "${new_version}" "${new_rev}" && (( CASCADE_CHANGED == 0 )); then
      echo "Already up to date (${new_version})."
      exit 0
    fi
    run_artifact_hook "${new_rev}" "${new_version}"
    if [[ "${HASH_MODE}" == "build-failure" ]]; then
      new_hash=""
    else
      echo "Computing source hash for ${GITLAB_OWNER}/${GITLAB_REPO}@${new_rev}..."
      new_hash=$(nix-prefetch-git --quiet --url "https://gitlab.com/${GITLAB_OWNER}/${GITLAB_REPO}.git" --rev "${new_rev}" | jq -r '.hash')
    fi
    echo "Writing pin.nix (-> ${new_version})..."
    write_source_pin "${new_version}" "${new_rev}" "${new_hash}"
    pin_changed=1
    if [[ -n "${BUILD_FAILURE_HASH}" ]]; then
      revalidate_hash "${BUILD_FAILURE_HASH}"
    fi
    ;;

  *)
    echo "error: unknown SOURCE_TYPE=${SOURCE_TYPE}" >&2
    exit 1
    ;;
esac

if [[ -n "${SKIP_BUILD}" ]]; then
  echo "SKIP_BUILD set; skipping build verification of ${BUILD_ATTR}."
else
  echo "Verifying build (${BUILD_ATTR})..."
  nix build --option post-build-hook "" "${FLAKE_ROOT}#${BUILD_ATTR}" --no-link
fi

echo
if (( pin_changed )); then
  echo "Updated ${BUILD_ATTR} to ${new_version}."
else
  echo "${BUILD_ATTR}: pin unchanged (${new_version})."
fi
echo "  Commit pin.nix / flake.nix / flake.lock to capture."
