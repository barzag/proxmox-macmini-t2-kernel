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
CONFIG_FILE="${PVE_DIR}/debian/rules.d/config-amd64.opts"

if [[ -z "${PVE_SHA:-}" ]]; then
  echo "ERROR: PVE_SHA is not defined" >&2
  exit 1
fi

if [[ -z "${T2_SHA:-}" ]]; then
  echo "ERROR: T2_SHA is not defined" >&2
  exit 1
fi

if [[ -z "${EXPECTED_PATCH_COUNT:-}" ]]; then
  echo "ERROR: EXPECTED_PATCH_COUNT is not defined" >&2
  exit 1
fi

# This must be the fingerprint of the exact effective patchset selected by
# validate-patches.sh, not the pristine upstream T2 patchset fingerprint.
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

if [[ ! -d "${EFFECTIVE_T2_DIR}" ]]; then
  echo "ERROR: effective T2 patch directory is missing: ${EFFECTIVE_T2_DIR}" >&2
  exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: Proxmox amd64 configuration file is missing" >&2
  exit 1
fi

echo "Target model:       ${T2_TARGET_MODEL}"
echo "Profile:            ${T2_PROFILE_NAME}"
echo "Effective patches:  ${EFFECTIVE_T2_DIR}"
echo "Preparing minimal T2 build tree..."

ACTUAL_PVE_SHA="$(git -C "${PVE_DIR}" rev-parse HEAD)"
ACTUAL_T2_SHA="$(git -C "${T2_DIR}" rev-parse HEAD)"

if [[ "${ACTUAL_PVE_SHA}" != "${PVE_SHA}" ]]; then
  echo "ERROR: unexpected Proxmox source SHA" >&2
  echo "Expected: ${PVE_SHA}" >&2
  echo "Actual:   ${ACTUAL_PVE_SHA}" >&2
  exit 1
fi

if [[ "${ACTUAL_T2_SHA}" != "${T2_SHA}" ]]; then
  echo "ERROR: unexpected T2 source SHA" >&2
  echo "Expected: ${T2_SHA}" >&2
  echo "Actual:   ${ACTUAL_T2_SHA}" >&2
  exit 1
fi

verify_macmini_t2_profile_files "${T2_DIR}"
verify_macmini_t2_effective_profile_files "${EFFECTIVE_T2_DIR}"

EFFECTIVE_FILE_COUNT="$(
  find "${EFFECTIVE_T2_DIR}" \
    -maxdepth 1 \
    -type f \
    -name '*.patch' |
  wc -l
)"

if [[ "${EFFECTIVE_FILE_COUNT}" -ne "${#MACMINI_T2_PATCHES[@]}" ]]; then
  echo "ERROR: effective T2 patch directory contains an unexpected number of patches" >&2
  echo "Expected: ${#MACMINI_T2_PATCHES[@]}" >&2
  echo "Actual:   ${EFFECTIVE_FILE_COUNT}" >&2
  exit 1
fi

while IFS= read -r PATCH_FILE; do
  PATCH_NAME="$(basename "${PATCH_FILE}")"

  if ! is_macmini_t2_allowlisted_patch "${PATCH_NAME}"; then
    echo "ERROR: unexpected patch in effective T2 directory: ${PATCH_NAME}" >&2
    exit 1
  fi
done < <(
  find "${EFFECTIVE_T2_DIR}" \
    -maxdepth 1 \
    -type f \
    -name '*.patch' \
    -print |
  sort -V
)

ACTUAL_PATCHSET_SHA="$(
  compute_macmini_t2_effective_patchset_sha "${EFFECTIVE_T2_DIR}"
)"

if [[ "${ACTUAL_PATCHSET_SHA}" != "${EXPECTED_PATCHSET_SHA}" ]]; then
  echo "ERROR: effective T2 patchset fingerprint changed unexpectedly" >&2
  echo "Expected: ${EXPECTED_PATCHSET_SHA}" >&2
  echo "Actual:   ${ACTUAL_PATCHSET_SHA}" >&2
  exit 1
fi

if [[ "${EXPECTED_PATCH_COUNT}" -ne "${#MACMINI_T2_PATCHES[@]}" ]]; then
  echo "ERROR: validated T2 patch count differs from profile allowlist" >&2
  echo "Expected from validator: ${EXPECTED_PATCH_COUNT}" >&2
  echo "Profile allowlist:       ${#MACMINI_T2_PATCHES[@]}" >&2
  exit 1
fi

rm -f "${PVE_DIR}"/patches/kernel/t2-*.patch

T2_PATCH_COUNT=0

for PATCH_NAME in "${MACMINI_T2_PATCHES[@]}"; do
  PATCH_SOURCE="${EFFECTIVE_T2_DIR}/${PATCH_NAME}"
  PATCH_DESTINATION="${PVE_DIR}/patches/kernel/t2-${PATCH_NAME}"

  echo "T2 STAGE -> ${PATCH_NAME}"

  cp \
    "${PATCH_SOURCE}" \
    "${PATCH_DESTINATION}"

  if ! cmp -s "${PATCH_SOURCE}" "${PATCH_DESTINATION}"; then
    echo "ERROR: staged T2 patch differs from validated source: ${PATCH_NAME}" >&2
    exit 1
  fi

  T2_PATCH_COUNT=$((T2_PATCH_COUNT + 1))
done

if [[ "${T2_PATCH_COUNT}" -ne "${EXPECTED_PATCH_COUNT}" ]]; then
  echo "ERROR: T2 staged patch count mismatch" >&2
  echo "Expected: ${EXPECTED_PATCH_COUNT}" >&2
  echo "Staged:   ${T2_PATCH_COUNT}" >&2
  exit 1
fi

if [[ "${T2_PATCH_COUNT}" -ne "${#MACMINI_T2_PATCHES[@]}" ]]; then
  echo "ERROR: T2 staged patch count differs from profile allowlist" >&2
  exit 1
fi

STAGED_COUNT="$(
  find "${PVE_DIR}/patches/kernel" \
    -maxdepth 1 \
    -type f \
    -name 't2-*.patch' |
  wc -l
)"

if [[ "${STAGED_COUNT}" -ne "${T2_PATCH_COUNT}" ]]; then
  echo "ERROR: final T2 staged patch count mismatch" >&2
  echo "Expected: ${T2_PATCH_COUNT}" >&2
  echo "Actual:   ${STAGED_COUNT}" >&2
  exit 1
fi

# Recompute the fingerprint from the exact files staged into the Proxmox patch
# directory. This proves that the compiler will consume the same patch content
# that validate-patches.sh approved.
STAGED_PATCHSET_DIR="$(
  mktemp -d
)"

cleanup()
{
  rm -rf "${STAGED_PATCHSET_DIR}"
}

trap cleanup EXIT

for PATCH_NAME in "${MACMINI_T2_PATCHES[@]}"; do
  cp \
    "${PVE_DIR}/patches/kernel/t2-${PATCH_NAME}" \
    "${STAGED_PATCHSET_DIR}/${PATCH_NAME}"
done

STAGED_PATCHSET_SHA="$(
  compute_macmini_t2_effective_patchset_sha "${STAGED_PATCHSET_DIR}"
)"

if [[ "${STAGED_PATCHSET_SHA}" != "${EXPECTED_PATCHSET_SHA}" ]]; then
  echo "ERROR: staged T2 patchset fingerprint differs from validated patchset" >&2
  echo "Expected: ${EXPECTED_PATCHSET_SHA}" >&2
  echo "Staged:   ${STAGED_PATCHSET_SHA}" >&2
  exit 1
fi

if ! grep -Fqx \
  'EXTRAVERSION=-$(KREL)$(KREL_EXTRA)-pve' \
  "${PVE_DIR}/Makefile"
then
  echo "ERROR: expected Proxmox EXTRAVERSION was not found" >&2
  exit 1
fi

sed -i \
  's|EXTRAVERSION=-$(KREL)$(KREL_EXTRA)-pve|EXTRAVERSION=-$(KREL)$(KREL_EXTRA)-pve-t2|' \
  "${PVE_DIR}/Makefile"

if ! grep -Fqx \
  'EXTRAVERSION=-$(KREL)$(KREL_EXTRA)-pve-t2' \
  "${PVE_DIR}/Makefile"
then
  echo "ERROR: unable to set pve-t2 kernel suffix" >&2
  exit 1
fi

# Minimal kernel configuration.
# Do NOT import the complete T2Linux extra_config: it enables BCE, GMUX,
# Touch Bar, APFS and other components outside this Macmini8,1 profile.
{
  echo
  echo "# BEGIN pve-t2-kernel configuration for ${T2_TARGET_MODEL}"
  echo "-m SENSORS_APPLESMC"
  echo "# END pve-t2-kernel configuration for ${T2_TARGET_MODEL}"
} >> "${CONFIG_FILE}"

T2_CONFIG_COUNT=1

echo
echo "Minimal T2 build integration ready."
echo "Target:             ${T2_TARGET_MODEL}"
echo "T2 patches staged:  ${T2_PATCH_COUNT}"
echo "T2 config options:  ${T2_CONFIG_COUNT}"
echo "Kernel suffix:      -pve-t2"
echo "Patch profile:      ${T2_PROFILE_NAME}"
echo "Patchset SHA256:    ${STAGED_PATCHSET_SHA}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "target=${T2_TARGET_MODEL}"
    echo "patch_count=${T2_PATCH_COUNT}"
    echo "config_count=${T2_CONFIG_COUNT}"
    echo "suffix=pve-t2"
    echo "patchset_sha=${STAGED_PATCHSET_SHA}"
  } >> "${GITHUB_OUTPUT}"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "${GITHUB_STEP_SUMMARY}" <<EOF_SUMMARY

## Minimal T2 build integration
- Target hardware: \`${T2_TARGET_MODEL}\`
- T2 patches staged: \`${T2_PATCH_COUNT}\`
- T2 configuration directives: \`${T2_CONFIG_COUNT}\`
- Kernel suffix: \`-pve-t2\`
- T2 profile: ${T2_PROFILE_NAME}
- Effective T2 patchset SHA256: \`${STAGED_PATCHSET_SHA}\`
EOF_SUMMARY
fi
