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

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: Proxmox amd64 configuration file is missing" >&2
  exit 1
fi

echo "Target model: ${T2_TARGET_MODEL}"
echo "Profile:      ${T2_PROFILE_NAME}"
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

ACTUAL_PATCHSET_SHA="$(
  compute_macmini_t2_patchset_sha "${T2_DIR}"
)"

if [[ "${ACTUAL_PATCHSET_SHA}" != "${EXPECTED_PATCHSET_SHA}" ]]; then
  echo "ERROR: T2 patchset fingerprint changed unexpectedly" >&2
  echo "Expected: ${EXPECTED_PATCHSET_SHA}" >&2
  echo "Actual:   ${ACTUAL_PATCHSET_SHA}" >&2
  exit 1
fi

rm -f "${PVE_DIR}"/patches/kernel/t2-*.patch

T2_PATCH_COUNT=0

for PATCH_NAME in "${MACMINI_T2_PATCHES[@]}"; do
  PATCH_SOURCE="${T2_DIR}/${PATCH_NAME}"

  echo "T2 STAGE -> ${PATCH_NAME}"

  cp \
    "${PATCH_SOURCE}" \
    "${PVE_DIR}/patches/kernel/t2-${PATCH_NAME}"

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

STAGED_COUNT="$(
  find "${PVE_DIR}/patches/kernel" \
    -maxdepth 1 \
    -type f \
    -name 't2-*.patch' |
  wc -l
)"

if [[ "${STAGED_COUNT}" -ne "${T2_PATCH_COUNT}" ]]; then
  echo "ERROR: final T2 patch count mismatch" >&2
  exit 1
fi

echo
echo "Minimal T2 build integration ready."
echo "Target:             ${T2_TARGET_MODEL}"
echo "T2 patches staged:  ${T2_PATCH_COUNT}"
echo "T2 config options:  ${T2_CONFIG_COUNT}"
echo "Kernel suffix:      -pve-t2"
echo "Patch profile:      ${T2_PROFILE_NAME}"
echo "Patchset SHA256:    ${ACTUAL_PATCHSET_SHA}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "target=${T2_TARGET_MODEL}"
    echo "patch_count=${T2_PATCH_COUNT}"
    echo "config_count=${T2_CONFIG_COUNT}"
    echo "suffix=pve-t2"
    echo "patchset_sha=${ACTUAL_PATCHSET_SHA}"
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
- T2 patchset SHA256: \`${ACTUAL_PATCHSET_SHA}\`
EOF_SUMMARY
fi
