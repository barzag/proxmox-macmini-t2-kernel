#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)"

# shellcheck source=t2-profile-macmini8-1.sh
source "${SCRIPT_DIR}/t2-profile-macmini8-1.sh"

T2_DIR="${T2_DIR:-linux-t2-patches}"
T2_REPOSITORY="${T2_REPOSITORY:-https://github.com/t2linux/linux-t2-patches.git}"
T2_BRANCH="${T2_BRANCH:-main}"

if [[ -z "${PVE_KERNEL:-}" ]]; then
  echo "ERROR: PVE_KERNEL is not defined" >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is not available" >&2
  exit 1
}

command -v sha256sum >/dev/null 2>&1 || {
  echo "ERROR: sha256sum is not available" >&2
  exit 1
}

PVE_SERIES="$(
  printf '%s\n' "${PVE_KERNEL}" |
  sed -E 's/^([0-9]+\.[0-9]+).*/\1/'
)"

if [[ ! "${PVE_SERIES}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: unable to determine Proxmox kernel series from ${PVE_KERNEL}" >&2
  exit 1
fi

echo "Resolving T2 patch candidate"
echo "Target:              ${T2_TARGET_MODEL}"
echo "Profile:             ${T2_PROFILE_NAME}"
echo "Proxmox kernel:      ${PVE_KERNEL}"
echo "Required T2 series:  ${PVE_SERIES}"

if [[ -e "${T2_DIR}" ]]; then
  echo "ERROR: ${T2_DIR} already exists" >&2
  exit 1
fi

#
# Clone the T2 source repository.
#

if ! git clone \
  --filter=blob:none \
  --no-checkout \
  --single-branch \
  --branch "${T2_BRANCH}" \
  "${T2_REPOSITORY}" \
  "${T2_DIR}"
then
  echo "WARN: partial T2 clone failed; retrying regular clone" >&2

  rm -rf "${T2_DIR}"

  git clone \
    --no-checkout \
    --single-branch \
    --branch "${T2_BRANCH}" \
    "${T2_REPOSITORY}" \
    "${T2_DIR}"
fi

#
# Find the most recent T2 revision matching the Proxmox kernel series.
#

T2_SHA=""
T2_KVER=""

while read -r COMMIT; do

  KVER="$(
    git -C "${T2_DIR}" \
      show "${COMMIT}:version" \
      2>/dev/null |
    sed -n 's/^KVER=//p' |
    tr -d '\r\n' ||
    true
  )"

  [[ -n "${KVER}" ]] || continue

  T2_SERIES="$(
    printf '%s\n' "${KVER}" |
    sed -E 's/^([0-9]+\.[0-9]+).*/\1/'
  )"

  if [[ "${T2_SERIES}" == "${PVE_SERIES}" ]]; then
    T2_SHA="${COMMIT}"
    T2_KVER="${KVER}"
    break
  fi

done < <(
  git -C "${T2_DIR}" rev-list "origin/${T2_BRANCH}"
)

if [[ -z "${T2_SHA}" ]]; then
  echo "ERROR: no T2 candidate found for kernel series ${PVE_SERIES}" >&2
  exit 1
fi

#
# Lock the T2 repository to the exact resolved revision.
#

git -C "${T2_DIR}" checkout --detach "${T2_SHA}"

ACTUAL_T2_SHA="$(
  git -C "${T2_DIR}" rev-parse HEAD
)"

if [[ "${ACTUAL_T2_SHA}" != "${T2_SHA}" ]]; then
  echo "ERROR: T2 checkout does not match resolved SHA" >&2
  echo "Expected: ${T2_SHA}" >&2
  echo "Actual:   ${ACTUAL_T2_SHA}" >&2
  exit 1
fi

#
# Verify the exact Macmini8,1 profile and compute a fingerprint only from
# the patches that are actually used by this kernel.
#
# This is intentionally independent from unrelated upstream T2 changes.
#

verify_macmini_t2_profile_files "${T2_DIR}"

T2_PATCHSET_SHA="$(
  compute_macmini_t2_patchset_sha "${T2_DIR}"
)"

if [[ ! "${T2_PATCHSET_SHA}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: unable to compute Macmini8,1 T2 patchset fingerprint" >&2
  exit 1
fi

T2_SUBJECT="$(
  git -C "${T2_DIR}" \
    show \
    -s \
    --format='%s' \
    "${T2_SHA}"
)"

#
# Detect new upstream patches that might be relevant to the Macmini8,1
# profile but are not currently allowlisted.
#
# Detection does NOT mean automatic inclusion. New patches must be
# explicitly reviewed and manually added to the profile.
#

mapfile -t REVIEW_PATCHES < <(
  while IFS= read -r PATCH_FILE; do

    if is_potential_new_macmini_t2_patch "${PATCH_FILE}"; then
      basename "${PATCH_FILE}"
    fi

  done < <(
    find "${T2_DIR}" \
      -maxdepth 1 \
      -type f \
      -name '*.patch' \
      -print |
    sort -V
  )
)

REVIEW_COUNT="${#REVIEW_PATCHES[@]}"
REVIEW_PATCHES_CSV=""

if [[ "${REVIEW_COUNT}" -gt 0 ]]; then
  REVIEW_PATCHES_CSV="$(
    IFS=,
    printf '%s' "${REVIEW_PATCHES[*]}"
  )"
fi

#
# Result
#

echo
echo "Resolved T2 candidate:"
echo "SHA:               ${T2_SHA}"
echo "KVER:              ${T2_KVER}"
echo "Commit:            ${T2_SUBJECT}"
echo "Target:            ${T2_TARGET_MODEL}"
echo "Profile patches:   ${#MACMINI_T2_PATCHES[@]}"
echo "Patchset SHA256:   ${T2_PATCHSET_SHA}"
echo "Review candidates: ${REVIEW_COUNT}"

if [[ "${REVIEW_COUNT}" -gt 0 ]]; then

  echo
  echo "Potential new Macmini8,1-relevant T2 patches detected:"

  for PATCH_NAME in "${REVIEW_PATCHES[@]}"; do
    echo "  - ${PATCH_NAME}"
  done

  echo
  echo "These patches are NOT applied automatically."
  echo "Manual profile review is required before adding any of them."

  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=Potential Macmini8,1 T2 patch review required::${REVIEW_PATCHES_CSV}"
  fi
fi

#
# GitHub Actions outputs
#

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "sha=${T2_SHA}"
    echo "kver=${T2_KVER}"
    echo "subject=${T2_SUBJECT}"
    echo "patchset_sha=${T2_PATCHSET_SHA}"
    echo "profile_patch_count=${#MACMINI_T2_PATCHES[@]}"
    echo "review_count=${REVIEW_COUNT}"
    echo "review_patches=${REVIEW_PATCHES_CSV}"
  } >> "${GITHUB_OUTPUT}"
fi

#
# GitHub Actions summary
#

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo
    echo "## T2 Macmini8,1 source"
    echo "- T2 source SHA: \`${T2_SHA}\`"
    echo "- T2 kernel target: \`${T2_KVER}\`"
    echo "- Macmini8,1 patchset SHA256: \`${T2_PATCHSET_SHA}\`"
    echo "- Allowlisted patches: \`${#MACMINI_T2_PATCHES[@]}\`"
    echo "- Potential new patches requiring review: \`${REVIEW_COUNT}\`"

    if [[ "${REVIEW_COUNT}" -gt 0 ]]; then
      echo
      echo "### Manual review required"

      for PATCH_NAME in "${REVIEW_PATCHES[@]}"; do
        echo "- \`${PATCH_NAME}\`"
      done

      echo
      echo "These patches are intentionally not applied automatically."
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi
