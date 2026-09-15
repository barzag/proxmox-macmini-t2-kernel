#!/usr/bin/env bash

# Shared T2 profile for Mac mini 2018 (Macmini8,1).
#
# This file is sourced by the resolver, compatibility validator and integration
# script. Keeping the profile in one place prevents the three stages from
# silently drifting apart.

T2_TARGET_MODEL="Macmini8,1"
T2_PROFILE_NAME="AppleSMC / thermal sensors / fan support only"

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

compute_macmini_t2_patchset_sha()
{
  local t2_dir="$1"
  local patch

  verify_macmini_t2_profile_files "${t2_dir}" || return 1

  {
    for patch in "${MACMINI_T2_PATCHES[@]}"; do
      printf 'FILE:%s\n' "${patch}"
      cat "${t2_dir}/${patch}"
      printf '\nEND:%s\n' "${patch}"
    done
  } | sha256sum | awk '{print $1}'
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
