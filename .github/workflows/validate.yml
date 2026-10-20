#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)"

# shellcheck source=t2-profile-macmini8-1.sh
source "${SCRIPT_DIR}/t2-profile-macmini8-1.sh"

PVE_DIR="${PVE_DIR:-proxmox-pve-kernel}"
T2_DIR="${T2_DIR:-linux-t2-patches}"
EFFECTIVE_T2_DIR="${EFFECTIVE_T2_DIR:-${T2_REPOSITORY_ROOT}/.t2-effective-patches}"
KERNEL_COMPAT_DIR="${KERNEL_COMPAT_DIR:-${T2_REPOSITORY_ROOT}/kernel-compat}"

if [[ -z "${PVE_SHA:-}" ]]; then
  echo "ERROR: PVE_SHA is not defined" >&2
  exit 1
fi

if [[ -z "${T2_SHA:-}" ]]; then
  echo "ERROR: T2_SHA is not defined" >&2
  exit 1
fi

# This is the fingerprint produced by resolve-t2.sh for the pristine upstream
# allowlist at the pinned T2 revision. It is intentionally NOT the final build
# fingerprint when a reviewed compatibility replacement is selected.
if [[ -z "${EXPECTED_PATCHSET_SHA:-}" ]]; then
  echo "ERROR: EXPECTED_PATCHSET_SHA is not defined" >&2
  exit 1
fi

if [[ ! -d "${PVE_DIR}/.git" ]]; then
  echo "ERROR: ${PVE_DIR} repository is missing" >&2
  exit 1
fi

if [[ ! -d "${T2_DIR}/.git" ]]; then
  echo "ERROR: ${T2_DIR} repository is missing" >&2
  exit 1
fi

# Resolve repository directories to absolute paths before entering the temporary
# kernel tree. This prevents later patch lookups from depending on the current
# working directory.
PVE_DIR="$(
  cd -- "${PVE_DIR}" >/dev/null 2>&1
  pwd
)"

T2_DIR="$(
  cd -- "${T2_DIR}" >/dev/null 2>&1
  pwd
)"

verify_macmini_t2_compat_files

echo "Testing compatibility:"
echo "Target:                    ${T2_TARGET_MODEL}"
echo "Profile:                   ${T2_PROFILE_NAME}"
echo "Proxmox SHA:               ${PVE_SHA}"
echo "T2 SHA:                    ${T2_SHA}"
echo "Upstream patchset SHA256:  ${EXPECTED_PATCHSET_SHA}"

git -C "${PVE_DIR}" checkout --detach "${PVE_SHA}"

git -C "${PVE_DIR}" config \
  submodule.submodules/ubuntu-kernel.url \
  https://git.proxmox.com/git/mirror_ubuntu-kernels.git

git -C "${PVE_DIR}" submodule update \
  --init \
  --depth 1 \
  submodules/ubuntu-kernel

git -C "${T2_DIR}" checkout --detach "${T2_SHA}"

verify_macmini_t2_profile_files "${T2_DIR}"

ACTUAL_UPSTREAM_PATCHSET_SHA="$(
  compute_macmini_t2_patchset_sha "${T2_DIR}"
)"

if [[ "${ACTUAL_UPSTREAM_PATCHSET_SHA}" != "${EXPECTED_PATCHSET_SHA}" ]]; then
  echo "ERROR: upstream T2 patchset fingerprint changed unexpectedly" >&2
  echo "Expected: ${EXPECTED_PATCHSET_SHA}" >&2
  echo "Actual:   ${ACTUAL_UPSTREAM_PATCHSET_SHA}" >&2
  exit 1
fi

TOTAL_T2_PATCHES="$(
  find "${T2_DIR}" \
    -maxdepth 1 \
    -type f \
    -name '*.patch' |
  wc -l
)"

REQUIRED_PATCH_COUNT="${#MACMINI_T2_PATCHES[@]}"
T2_SKIPPED=$((TOTAL_T2_PATCHES - REQUIRED_PATCH_COUNT))

if [[ "${T2_SKIPPED}" -lt 0 ]]; then
  echo "ERROR: invalid T2 patch repository state" >&2
  exit 1
fi

rm -rf "${KERNEL_COMPAT_DIR}" "${EFFECTIVE_T2_DIR}"
mkdir -p "${EFFECTIVE_T2_DIR}"

cp -a \
  "${PVE_DIR}/submodules/ubuntu-kernel" \
  "${KERNEL_COMPAT_DIR}"

rm -rf \
  "${KERNEL_COMPAT_DIR}/debian" \
  "${KERNEL_COMPAT_DIR}/debian.master"

cd "${KERNEL_COMPAT_DIR}"

echo
echo "Applying official Proxmox patches..."

for patchfile in "${PVE_DIR}"/patches/kernel/*.patch; do
  [[ -e "${patchfile}" ]] || continue

  PATCH_NAME="$(basename "${patchfile}")"

  echo "PVE -> ${PATCH_NAME}"

  if ! patch \
    --batch \
    -p1 \
    < "${patchfile}" \
    > /tmp/pve-patch.log 2>&1
  then
    cat /tmp/pve-patch.log
    echo "ERROR: official Proxmox patch failed: ${PATCH_NAME}" >&2
    exit 1
  fi
done

echo
echo "Selecting and applying Macmini8,1 T2 patches..."

T2_COUNT=0
COMPAT_OVERRIDE_COUNT=0
COMPAT_OVERRIDES=()

write_blocked_outputs()
{
  local failed_patch="$1"

  rm -rf "${EFFECTIVE_T2_DIR}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "compatible=false"
      echo "failed_patch=${failed_patch}"
      echo "patch_count=${T2_COUNT}"
      echo "skipped_count=${T2_SKIPPED}"
      echo "skipped_patch=non-Macmini8,1 T2 patches"
      echo "upstream_patchset_sha=${ACTUAL_UPSTREAM_PATCHSET_SHA}"
      echo "patchset_sha="
      echo "compat_override_count=${COMPAT_OVERRIDE_COUNT}"
      echo "compat_overrides=$(
        IFS=,
        printf '%s' "${COMPAT_OVERRIDES[*]}"
      )"
      echo "effective_dir="
    } >> "${GITHUB_OUTPUT}"
  fi

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo
      echo "## T2 compatibility blocked"
      echo "- Failed patch: \`${failed_patch}\`"
      echo "- Applied before failure: \`${T2_COUNT}\`"
      echo "- Result: **no build and no release**"
      echo
      echo "The upstream patch and every explicitly reviewed compatibility"
      echo "replacement for this patch failed strict application checks."
      echo "Manual review is required before this kernel can be built."
    } >> "${GITHUB_STEP_SUMMARY}"
  fi

  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=T2 compatibility blocked::${failed_patch} requires manual review; build and release are disabled."
  fi
}

for PATCH_NAME in "${MACMINI_T2_PATCHES[@]}"; do
  UPSTREAM_PATCH_FILE="${T2_DIR}/${PATCH_NAME}"
  SELECTED_PATCH_FILE=""
  SELECTED_SOURCE="upstream"

  echo "T2 -> ${PATCH_NAME}"

  if patch \
    --dry-run \
    --batch \
    --forward \
    --fuzz=0 \
    -p1 \
    < "${UPSTREAM_PATCH_FILE}" \
    > /tmp/t2-upstream-patch.log 2>&1
  then
    SELECTED_PATCH_FILE="${UPSTREAM_PATCH_FILE}"
  else
    echo "  upstream patch does not apply strictly"

    if is_macmini_t2_compat_patch "${PATCH_NAME}"; then
      COMPAT_PATCH_FILE="$(
        macmini_t2_compat_patch_file "${PATCH_NAME}"
      )"

      echo "  testing reviewed compatibility replacement"

      if patch \
        --dry-run \
        --batch \
        --forward \
        --fuzz=0 \
        -p1 \
        < "${COMPAT_PATCH_FILE}" \
        > /tmp/t2-compat-patch.log 2>&1
      then
        SELECTED_PATCH_FILE="${COMPAT_PATCH_FILE}"
        SELECTED_SOURCE="compat"
      else
        echo
        echo "Upstream patch dry-run:"
        cat /tmp/t2-upstream-patch.log
        echo
        echo "Reviewed compatibility patch dry-run:"
        cat /tmp/t2-compat-patch.log
      fi
    else
      cat /tmp/t2-upstream-patch.log
    fi
  fi

  if [[ -z "${SELECTED_PATCH_FILE}" ]]; then
    echo "BLOCKED: no reviewed patch applies cleanly: ${PATCH_NAME}" >&2
    write_blocked_outputs "${PATCH_NAME}"
    exit 0
  fi

  if ! patch \
    --batch \
    --forward \
    --fuzz=0 \
    -p1 \
    < "${SELECTED_PATCH_FILE}" \
    > /tmp/t2-patch.log 2>&1
  then
    cat /tmp/t2-patch.log
    echo "ERROR: selected T2 patch passed dry-run but failed during application: ${PATCH_NAME}" >&2
    exit 1
  fi

  cp \
    "${SELECTED_PATCH_FILE}" \
    "${EFFECTIVE_T2_DIR}/${PATCH_NAME}"

  if [[ "${SELECTED_SOURCE}" == "compat" ]]; then
    COMPAT_OVERRIDE_COUNT=$((COMPAT_OVERRIDE_COUNT + 1))
    COMPAT_OVERRIDES+=("${PATCH_NAME}")
    echo "  selected: reviewed compatibility replacement"
  else
    echo "  selected: upstream"
  fi

  T2_COUNT=$((T2_COUNT + 1))
done

if [[ "${T2_COUNT}" -ne "${REQUIRED_PATCH_COUNT}" ]]; then
  echo "ERROR: unexpected applied T2 patch count" >&2
  echo "Expected: ${REQUIRED_PATCH_COUNT}"
  echo "Applied:  ${T2_COUNT}"
  exit 1
fi

EFFECTIVE_PATCHSET_SHA="$(
  compute_macmini_t2_effective_patchset_sha "${EFFECTIVE_T2_DIR}"
)"

if [[ ! "${EFFECTIVE_PATCHSET_SHA}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: unable to compute effective Macmini8,1 patchset fingerprint" >&2
  exit 1
fi

COMPAT_OVERRIDES_CSV="$(
  IFS=,
  printf '%s' "${COMPAT_OVERRIDES[*]}"
)"

echo
echo "Patch compatibility passed."
echo "Target:                    ${T2_TARGET_MODEL}"
echo "Applied:                   ${T2_COUNT}"
echo "Ignored:                   ${T2_SKIPPED} non-Macmini8,1 T2 patches"
echo "Reviewed overrides used:   ${COMPAT_OVERRIDE_COUNT}"
echo "Profile:                   ${T2_PROFILE_NAME}"
echo "Upstream patchset SHA256:  ${ACTUAL_UPSTREAM_PATCHSET_SHA}"
echo "Effective patchset SHA256: ${EFFECTIVE_PATCHSET_SHA}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "compatible=true"
    echo "failed_patch="
    echo "patch_count=${T2_COUNT}"
    echo "skipped_count=${T2_SKIPPED}"
    echo "skipped_patch=non-Macmini8,1 T2 patches"
    echo "upstream_patchset_sha=${ACTUAL_UPSTREAM_PATCHSET_SHA}"
    echo "patchset_sha=${EFFECTIVE_PATCHSET_SHA}"
    echo "compat_override_count=${COMPAT_OVERRIDE_COUNT}"
    echo "compat_overrides=${COMPAT_OVERRIDES_CSV}"
    echo "effective_dir=${EFFECTIVE_T2_DIR}"
  } >> "${GITHUB_OUTPUT}"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo
    echo "## T2 compatibility"
    echo "- Compatible: **true**"
    echo "- T2 patches applied: \`${T2_COUNT}\`"
    echo "- Reviewed compatibility replacements used: \`${COMPAT_OVERRIDE_COUNT}\`"
    echo "- Compatibility replacements: \`${COMPAT_OVERRIDES_CSV:-none}\`"
    echo "- Upstream patchset SHA256: \`${ACTUAL_UPSTREAM_PATCHSET_SHA}\`"
    echo "- Effective patchset SHA256: \`${EFFECTIVE_PATCHSET_SHA}\`"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
