#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#curl nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#nix nixpkgs#coreutils --command bash

# Per-version branch orchestrator. Runs on main, once per workflow run.
#
# For each upstream version >= $MINIMUM_TRACKING_VERSION, ensures:
#   - an exact branch `v<M>.<m>.<p>` exists and its pin is hash-validated
#   - aggregate pointer branches `v<M>.<m>`, `v<M>`, `main` are force-pushed to the highest matching exact branch (only the levels shorter than a version's component count; `main` always)
#
# Single knob: $MINIMUM_TRACKING_VERSION. Permanent pins are done via git tags (which the action never touches); there is no in-band freeze list.
#
# Each existing exact branch is `git merge`d with origin/main before its update-version runs, so orchestrator/workflow improvements that land on main propagate forward through every branch's tree. Branch-owned files (pin.nix, flake.lock, flake.nix, ...) stay as-is via the `ours` merge driver declared in .gitattributes. The shared scripts come from the flake-lib input, so the per-branch `nix flake update` below picks up their improvements automatically.
#
# Failures: per-branch update-version failures are surfaced as GH Actions ::warning::
# annotations + a step summary, and cause a non-zero exit at the end of the run.
#
# Per-flake variation is driven by env vars injected by flake-lib's mkUpdateBranches:
#   SOURCE_TYPE          pypi | github | github-release-asset  (gitlab leaves are single-branch, no orchestrator)
#   PYPI_NAME            [pypi]
#   PYPI_FORMAT          sdist | wheel  [pypi]
#   GH_OWNER/GH_REPO     [github, github-release-asset]
#   PIN_SCHEMA           pypi | github | github-npm | github-pnpm | github-yarn | github-asset | version-only
#   BRANCH_OWNED_FILES   space-separated files update-version mutates per branch
#   VERSION_OVERRIDES    JSON map raw version -> canonical version
#   VERSION_CANON        newline-separated `sed -E` rules mapping raw version -> canonical version
#   MIN_VERSION_COMPONENTS  fewest dot-separated numeric components a tag may have and still be tracked (default 3)

set -euo pipefail
: "${MINIMUM_TRACKING_VERSION:?required env var}"
MIN_VERSION_COMPONENTS="${MIN_VERSION_COMPONENTS:-3}"

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

# Buffers output and emits it only on success, so a consumer never sees partial data from an attempt that died mid-stream (e.g. gh --paginate failing between pages).
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

list_upstream_versions() {
  case "${SOURCE_TYPE}" in
    pypi)
      # Only enumerate releases the flake can actually fetch: sdist -> a source tarball; wheel -> a universal py3-none-any wheel (the one mk-pypi-package builds). Releases lacking it are skipped.
      if [ "${PYPI_FORMAT:-sdist}" = "wheel" ]; then
        retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" \
          | jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "bdist_wheel" and (.filename | endswith("-py3-none-any.whl")))) | .key'
      else
        retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" \
          | jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "sdist")) | .key'
      fi
      ;;
    github | github-release-asset)
      retry gh api --paginate "/repos/${GH_OWNER}/${GH_REPO}/releases" --jq '.[].tag_name'
      ;;
    *)
      echo "error: update-branches does not support SOURCE_TYPE=${SOURCE_TYPE}" >&2
      exit 1
      ;;
  esac
}

prepare_new_branch_pin() {
  local VERSION="${1}" EXTRA_HASH
  case "${PIN_SCHEMA}" in
    pypi)
      {
        cat <<EOF
{
  version = "${VERSION}";
  hash = "";
EOF
        for EXTRA_HASH in $(jq -r '.[]' <<<"${EXTRA_HASHES:-[]}"); do
          echo "  ${EXTRA_HASH} = \"\";"
        done
        echo "}"
      } > pin.nix
      ;;
    github)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
}
EOF
      ;;
    github-npm)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
  npmDepsHash = "";
}
EOF
      ;;
    github-pnpm)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
  pnpmDepsHash = "";
}
EOF
      ;;
    github-yarn)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
  yarnHash = "";
}
EOF
      ;;
    github-asset)
      # Prebuilt release asset; URL is a GitHub release download (SOURCE_TYPE=github-release-asset in update-version.sh).
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  hash = "";
}
EOF
      ;;
    version-only)
      ;;
    *)
      echo "error: unknown PIN_SCHEMA=${PIN_SCHEMA}" >&2
      exit 1
      ;;
  esac
}

version_lt() { [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

is_prerelease() {
  local VERSION="${1}"
  [[ "${SOURCE_TYPE}" != "pypi" && "${VERSION%%+*}" == *-* ]] || python3 "${CASCADE_PY}" prerelease "${VERSION}"
}

canonicalize_version() {
  local v="$1" canon rule
  canon=$(jq -r --arg v "${v}" '.[$v] // ""' <<<"${VERSION_OVERRIDES}")
  if [[ -n "${canon}" ]]; then
    printf '%s' "${canon}"
    return
  fi
  canon="${v}"
  while IFS= read -r rule; do
    if [[ -n "${rule}" ]]; then
      canon=$(sed -E "${rule}" <<<"${canon}")
    fi
  done <<<"${VERSION_CANON}"
  printf '%s' "${canon}"
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Define the `ours` merge driver so .gitattributes' `merge=ours` rules take effect: `true` exits 0 without touching the file, leaving the branch's version.
git config merge.ours.driver true

echo "Querying upstream..."
mapfile -t raw_versions < <(list_upstream_versions)
if (( ${#raw_versions[@]} == 0 )); then
  echo "error: list_upstream_versions returned no rows (auth issue?)" >&2
  exit 1
fi
# Optional remap of upstream versions whose tag numbering doesn't sort correctly (see VERSION_OVERRIDES / VERSION_CANON in mkUpdateBranches). `all_versions` and everything downstream use the canonical form; `orig_of` recovers the raw upstream version so update-version still fetches the real tag.
VERSION_OVERRIDES="${VERSION_OVERRIDES:-}"
[[ -n "${VERSION_OVERRIDES}" ]] || VERSION_OVERRIDES='{}'
VERSION_CANON="${VERSION_CANON:-}"
version_re="^[0-9]+(\.[0-9]+){$((MIN_VERSION_COMPONENTS - 1)),2}([-+a-zA-Z0-9.]+)?$"
declare -a all_versions=()
declare -A orig_of=()
for v in "${raw_versions[@]}"; do
  v="${v#[Vv]}"
  if [[ "${v}" =~ ${version_re} ]]; then
    canon=$(canonicalize_version "${v}")
    all_versions+=("${canon}")
    orig_of["${canon}"]="${v}"
  fi
done

declare -a tracked=()
if [[ "${SOURCE_TYPE}" == "pypi" ]]; then
  mapfile -t tracked < <(printf '%s\n' "${all_versions[@]}" | python3 "${CASCADE_PY}" sort "${MINIMUM_TRACKING_VERSION}" all)
else
  for v in "${all_versions[@]}"; do
    if ! version_lt "${v}" "${MINIMUM_TRACKING_VERSION}"; then
      tracked+=("${v}")
    fi
  done
  mapfile -t tracked < <(printf '%s\n' "${tracked[@]}" | sort -V)
fi
if (( ${#tracked[@]} == 0 )); then
  echo "No upstream versions >= ${MINIMUM_TRACKING_VERSION}; nothing to do."
  exit 0
fi
echo "Tracking ${#tracked[@]} upstream versions: ${tracked[*]}"

git fetch --prune --quiet origin
main_sha=$(git rev-parse --verify origin/main)

declare -a failed=()

for v in "${tracked[@]}"; do
  branch="v${v}"
  wt=$(mktemp -d)
  if git rev-parse --verify --quiet "origin/${branch}" >/dev/null; then
    echo
    echo "=== Refreshing existing branch ${branch}"
    git fetch --quiet origin "${branch}:refs/remotes/origin/${branch}" || true
    git worktree add -B "${branch}" "${wt}" "origin/${branch}" >/dev/null
    # Merge orchestrator/workflow improvements from main; branch-owned files stay as-is per .gitattributes.
    (cd "${wt}" && git merge --no-edit origin/main)
  else
    echo
    echo "=== Creating new branch ${branch} from main"
    git worktree add -B "${branch}" "${wt}" "${main_sha}" >/dev/null
    (cd "${wt}" && prepare_new_branch_pin "${v}")
  fi
  pushd "${wt}" >/dev/null
  set +e
  nix flake update --option post-build-hook ""
  FLAKE_ROOT="${wt}" nix run --option post-build-hook "" .#update-version -- "${v}" "${orig_of[$v]}"
  uv_exit=$?
  set -e
  if (( uv_exit != 0 )); then
    failed+=("${v}")
    echo "::warning title=Branch ${branch} skipped::update-version failed for ${v} (exit ${uv_exit}). Likely an upstream defect at that release; see the orchestrator log above."
    echo "  WARN: update-version failed for ${branch} (exit ${uv_exit}); skipping." >&2
    popd >/dev/null
    git worktree remove --force "${wt}" >/dev/null
    continue
  fi
  # shellcheck disable=SC2086
  if ! git diff --quiet -- ${BRANCH_OWNED_FILES} || [[ -n "$(git ls-files --others --exclude-standard -- ${BRANCH_OWNED_FILES})" ]]; then
    # shellcheck disable=SC2086
    git add ${BRANCH_OWNED_FILES}
    git commit -q -m "auto: ${v} pin"
    git push --quiet origin "${branch}"
  else
    echo "  no change on ${branch}"
    # Merge may have advanced HEAD without touching tracked files we diff for; push if local HEAD is ahead of origin.
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${branch}")" ]]; then
      git push --quiet origin "${branch}"
    fi
  fi
  popd >/dev/null
  git worktree remove --force "${wt}" >/dev/null
done

git fetch --prune --quiet origin
declare -A agg_target_version=()
declare -A tracked_version=()
record() { local KEY="${1}" VERSION="${2}"; agg_target_version[${KEY}]="${VERSION}"; }
for v in "${tracked[@]}"; do
  tracked_version[${v}]=1
  # Only consider exact branches that actually exist on origin (failed branches won't have a ref to advance aggregates to). Checked against the just-pruned local refs, not via ls-remote — a transient network error misread as "absent" here would force-push aggregates backwards.
  if ! git rev-parse --verify --quiet "origin/v${v}" >/dev/null; then
    continue
  fi
  # Aggregates only for levels shorter than the version's component count, so a short version's exact branch (e.g. v2 for tag "2") is never clobbered by an aggregate push.
  IFS='.' read -r M m p <<<"${v}"
  record "main" "${v}"
  if [[ -n "${m}" ]]; then record "v${M}" "${v}"; fi
  if [[ -n "${p}" ]]; then record "v${M}.${m}" "${v}"; fi
done

echo
echo "=== Updating aggregate pointers"
for agg in "${!agg_target_version[@]}"; do
  target_v="${agg_target_version[$agg]}"
  if is_prerelease "${target_v}"; then
    STABLE_V="${target_v%%-*}"
    if [[ "${STABLE_V}" != "${target_v}" && -n "${tracked_version[${STABLE_V}]:-}" ]] && git rev-parse --verify --quiet "origin/v${STABLE_V}" >/dev/null; then
      target_v="${STABLE_V}"
    fi
  fi
  target_branch="v${target_v}"
  target_sha=$(git rev-parse --verify "origin/${target_branch}")
  cur_sha=$(git rev-parse --verify "origin/${agg}" 2>/dev/null || echo "")
  if [[ "${cur_sha}" == "${target_sha}" ]]; then
    echo "  ${agg} already at ${target_branch}"
    continue
  fi
  if is_prerelease "${target_v}" && [[ -n "${cur_sha}" ]]; then
    CURRENT_V=$(git show "${cur_sha}:pin.nix" | sed -nE 's/^[[:space:]]*version = "([^"]+)";$/\1/p' | head -1)
    if ! is_prerelease "${CURRENT_V}"; then
      CURRENT_BRANCH="v${CURRENT_V}"
      if [[ -n "${CURRENT_V}" ]] && git rev-parse --verify --quiet "origin/${CURRENT_BRANCH}" >/dev/null; then
        target_branch="${CURRENT_BRANCH}"
        target_sha=$(git rev-parse --verify "origin/${target_branch}")
      else
        echo "  ${agg} remains at its current stable target"
        continue
      fi
    fi
  fi
  if [[ "${cur_sha}" == "${target_sha}" ]]; then
    echo "  ${agg} already at ${target_branch}"
    continue
  fi
  echo "  ${agg} -> ${target_branch} (${target_sha:0:8})"
  git push --force --quiet origin "${target_sha}:refs/heads/${agg}"
done

echo
if (( ${#failed[@]} > 0 )); then
  echo "=== ${#failed[@]} branch(es) failed: ${failed[*]}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## :warning: ${#failed[@]} branch(es) failed to update"
      echo
      echo "These upstream versions couldn't be packaged. They were skipped; aggregate pointers reflect only the successful branches."
      echo
      for v in "${failed[@]}"; do
        echo "- \`v${v}\`"
      done
      echo
      echo "See the orchestrator log for the underlying error per version."
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

echo "Done."
