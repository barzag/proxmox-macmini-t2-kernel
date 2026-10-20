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
