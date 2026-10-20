#!/usr/bin/env bash

# Shared T2 profile for Mac mini 2018 (Macmini8,1).
#
# This file is sourced by the resolver, compatibility validator and integration
# script. Keeping the profile in one place prevents the three stages from
# silently drifting apart.

T2_TARGET_MODEL="Macmini8,1"
T2_PROFILE_NAME="AppleSMC / thermal sensors / fan support only"

T2_PROFILE_SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)"

T2_REPOSITORY_ROOT="$(
  cd -- "${T2_PROFILE_SCRIPT_DIR}/.." >/dev/null 2>&1
  pwd
)"

# Local, reviewed compatibility replacements.
# The environment variable remains overridable for tests.
MACMINI_T2_COMPAT_DIR="${MACMINI_T2_COMPAT_DIR:-${T2_REPOSITORY_ROOT}/patches/compat/applesmc}"

# Exact upstream patches intentionally included in the Macmini8,1 profile.
MACMINI_T2_PATCHES=(
  "3001-applesmc-convert-static-structures-to-drvdata.patch"
  "3002-applesmc-make-io-port-base-addr-dynamic.patch"
  "3003-applesmc-switch-to-acpi_device-from-platform.patch"
  "3004-applesmc-key-interface-wrappers.patch"
  "3005-applesmc-basic-mmio-interface-implementation.patch"
  "3006-applesmc-fan-support-on-T2-Macs.patch"
  "3008-applesmc-make-applesmc_remove-void.patch"
)

# Known AppleSMC patches that were reviewed and are intentionally excluded from
# this Mac mini profile. They should not trigger the "new potentially relevant
# patch" warning.
MACMINI_T2_REVIEWED_IGNORED_PATCHES=(
  "3007-applesmc-Add-iMacPro-to-applesmc_whitelist.patch"
  "3009-applesmc-battery-charge-limiter.patch"
)

# Reviewed local compatibility overrides.
#
# These are NOT additional patches. They may replace the corresponding upstream
# patch only after the normal upstream patch has failed a strict compatibility
# check. No file is automatically trusted merely because it exists in the
# compatibility directory.
MACMINI_T2_COMPAT_PATCHES=(
  "3001-applesmc-convert-static-structures-to-drvdata.patch"
)

is_macmini_t2_allowlisted_patch()
{
  local candidate="$1"
  local patch

  for patch in "${MACMINI_T2_PATCHES[@]}"; do
    [[ "${candidate}" == "${patch}" ]] && return 0
  done

  return 1
}

is_macmini_t2_reviewed_ignored_patch()
{
  local candidate="$1"
  local patch

  for patch in "${MACMINI_T2_REVIEWED_IGNORED_PATCHES[@]}"; do
    [[ "${candidate}" == "${patch}" ]] && return 0
  done

  return 1
}

is_macmini_t2_compat_patch()
{
  local candidate="$1"
  local patch

  for patch in "${MACMINI_T2_COMPAT_PATCHES[@]}"; do
    [[ "${candidate}" == "${patch}" ]] && return 0
  done

  return 1
}

macmini_t2_compat_patch_file()
{
  local patch_name="$1"
  local patch_file

  is_macmini_t2_compat_patch "${patch_name}" || return 1

  patch_file="${MACMINI_T2_COMPAT_DIR}/${patch_name}"

  if [[ ! -f "${patch_file}" ]]; then
    printf 'ERROR: reviewed compatibility patch is missing: %s\n' \
      "${patch_file}" >&2
    return 1
  fi

  printf '%s\n' "${patch_file}"
}

verify_macmini_t2_profile_files()
{
  local t2_dir="$1"
  local patch

  for patch in "${MACMINI_T2_PATCHES[@]}"; do
    if [[ ! -f "${t2_dir}/${patch}" ]]; then
      printf 'ERROR: required T2 patch is missing: %s\n' "${patch}" >&2
      return 1
    fi
  done
}

verify_macmini_t2_compat_files()
{
  local patch

  for patch in "${MACMINI_T2_COMPAT_PATCHES[@]}"; do
    if ! is_macmini_t2_allowlisted_patch "${patch}"; then
      printf \
        'ERROR: compatibility override is not part of the Macmini8,1 allowlist: %s\n' \
        "${patch}" >&2
      return 1
    fi

    if [[ ! -f "${MACMINI_T2_COMPAT_DIR}/${patch}" ]]; then
      printf 'ERROR: reviewed compatibility patch is missing: %s\n' \
        "${MACMINI_T2_COMPAT_DIR}/${patch}" >&2
      return 1
    fi
  done
}

verify_macmini_t2_effective_profile_files()
{
  local effective_dir="$1"
  local patch

  for patch in "${MACMINI_T2_PATCHES[@]}"; do
    if [[ ! -f "${effective_dir}/${patch}" ]]; then
      printf 'ERROR: effective T2 patch is missing: %s\n' \
        "${effective_dir}/${patch}" >&2
      return 1
    fi
  done
}

compute_macmini_t2_patchset_sha_from_dir()
{
  local patch_dir="$1"
  local patch

  verify_macmini_t2_effective_profile_files "${patch_dir}" || return 1

  {
    for patch in "${MACMINI_T2_PATCHES[@]}"; do
      printf 'FILE:%s\n' "${patch}"
      cat "${patch_dir}/${patch}"
      printf '\nEND:%s\n' "${patch}"
    done
  } | sha256sum | awk '{print $1}'
}

# Fingerprint of the exact upstream allowlisted patchset at the resolved T2
# revision. This preserves the existing resolver behaviour.
compute_macmini_t2_patchset_sha()
{
  local t2_dir="$1"

  verify_macmini_t2_profile_files "${t2_dir}" || return 1
  compute_macmini_t2_patchset_sha_from_dir "${t2_dir}"
}

# Fingerprint of the exact patch files selected by the compatibility validator.
# The validator will build an effective patch directory containing either the
# upstream patch or an explicitly reviewed compatibility replacement for every
# allowlisted patch.
compute_macmini_t2_effective_patchset_sha()
{
  local effective_dir="$1"

  compute_macmini_t2_patchset_sha_from_dir "${effective_dir}"
}

patch_matches_macmini_t2_pattern()
{
  local pattern="$1"
  local patch_file="$2"
  local patch_name

  patch_name="$(basename "${patch_file}")"

  grep -Eqi "${pattern}" <<< "${patch_name}" ||
    grep -Eqi "${pattern}" "${patch_file}"
}

is_potential_new_macmini_t2_patch()
{
  local patch_file="$1"
  local patch_name

  patch_name="$(basename "${patch_file}")"

  is_macmini_t2_allowlisted_patch "${patch_name}" && return 1
  is_macmini_t2_reviewed_ignored_patch "${patch_name}" && return 1

  # An explicit Mac mini reference is always worth manual review.
  if patch_matches_macmini_t2_pattern \
    'Macmini8,1|Macmini[0-9]+,[0-9]+|Mac[[:space:]_-]*mini' \
    "${patch_file}"
  then
    return 0
  fi

  # Generic AppleSMC changes can alter the exact driver chain used by this
  # profile. Exclude clearly laptop/iMac-only changes unless they also mention
  # fan, thermal or sensor support.
  if patch_matches_macmini_t2_pattern \
    'applesmc|apple[[:space:]_-]*smc|SENSORS_APPLESMC' \
    "${patch_file}"
  then
    if patch_matches_macmini_t2_pattern \
      'battery|charge[[:space:]_-]*limit|MacBook|iMacPro|Touch[[:space:]_-]*Bar|trackpad' \
      "${patch_file}" &&
       ! patch_matches_macmini_t2_pattern \
      'fan|thermal|temperature|sensor|Macmini|Mac[[:space:]_-]*mini' \
      "${patch_file}"
    then
      return 1
    fi

    return 0
  fi

  # Catch a new T2/Apple thermal or fan patch even if it does not use the
  # AppleSMC name explicitly.
  if patch_matches_macmini_t2_pattern \
    'fan|thermal|temperature|sensor' \
    "${patch_file}" &&
     patch_matches_macmini_t2_pattern \
    'T2|Apple|SMC|Macmini|Mac[[:space:]_-]*mini' \
    "${patch_file}"
  then
    return 0
  fi

  return 1
}
