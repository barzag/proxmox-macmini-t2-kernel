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

if [[ -z "${PVE_SHA:-}" ]]; then
  echo "ERROR: PVE_SHA is not defined" >&2
  exit 1
fi

if [[ -z "${T2_SHA:-}" ]]; then
  echo "ERROR: T2_SHA is not defined" >&2
  exit 1
fi

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

echo "Testing compatibility:"
echo "Target:          ${T2_TARGET_MODEL}"
echo "Profile:         ${T2_PROFILE_NAME}"
echo "Proxmox SHA:     ${PVE_SHA}"
echo "T2 SHA:          ${T2_SHA}"
echo "Patchset SHA256: ${EXPECTED_PATCHSET_SHA}"

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

ACTUAL_PATCHSET_SHA="$(
  compute_macmini_t2_patchset_sha "${T2_DIR}"
)"

if [[ "${ACTUAL_PATCHSET_SHA}" != "${EXPECTED_PATCHSET_SHA}" ]]; then
  echo "ERROR: T2 patchset fingerprint changed unexpectedly" >&2
  echo "Expected: ${EXPECTED_PATCHSET_SHA}" >&2
  echo "Actual:   ${ACTUAL_PATCHSET_SHA}" >&2
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

rm -rf kernel-compat

cp -a \
  "${PVE_DIR}/submodules/ubuntu-kernel" \
  kernel-compat

rm -rf \
  kernel-compat/debian \
  kernel-compat/debian.master

cd kernel-compat

echo
echo "Applying official Proxmox patches..."

for patchfile in "../${PVE_DIR}"/patches/kernel/*.patch; do
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
echo "Applying Macmini8,1 T2 allowlist..."

T2_COUNT=0

for PATCH_NAME in "${MACMINI_T2_PATCHES[@]}"; do
  PATCH_FILE="../${T2_DIR}/${PATCH_NAME}"

  echo "T2 -> ${PATCH_NAME}"

  if ! patch \
    --batch \
    -p1 \
    < "${PATCH_FILE}" \
    > /tmp/t2-patch.log 2>&1
  then
    cat /tmp/t2-patch.log

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "compatible=false"
        echo "failed_patch=${PATCH_NAME}"
        echo "patch_count=${T2_COUNT}"
        echo "skipped_count=${T2_SKIPPED}"
        echo "skipped_patch=non-Macmini8,1 T2 patches"
        echo "patchset_sha=${ACTUAL_PATCHSET_SHA}"
      } >> "${GITHUB_OUTPUT}"
    fi

    echo "ERROR: T2 patch failed: ${PATCH_NAME}" >&2
    exit 1
  fi

  T2_COUNT=$((T2_COUNT + 1))
done

if [[ "${T2_COUNT}" -ne "${REQUIRED_PATCH_COUNT}" ]]; then
  echo "ERROR: unexpected applied T2 patch count" >&2
  echo "Expected: ${REQUIRED_PATCH_COUNT}"
  echo "Applied:  ${T2_COUNT}"
  exit 1
fi

echo
echo "Patch compatibility passed."
echo "Target:          ${T2_TARGET_MODEL}"
echo "Applied:         ${T2_COUNT}"
echo "Ignored:         ${T2_SKIPPED} non-Macmini8,1 T2 patches"
echo "Profile:         ${T2_PROFILE_NAME}"
echo "Patchset SHA256: ${ACTUAL_PATCHSET_SHA}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "compatible=true"
    echo "failed_patch="
    echo "patch_count=${T2_COUNT}"
    echo "skipped_count=${T2_SKIPPED}"
    echo "skipped_patch=non-Macmini8,1 T2 patches"
    echo "patchset_sha=${ACTUAL_PATCHSET_SHA}"
  } >> "${GITHUB_OUTPUT}"
fi
