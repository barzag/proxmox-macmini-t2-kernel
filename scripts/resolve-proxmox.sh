#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

#
# Resolve the exact Proxmox pve-kernel source commit corresponding to the
# kernel package currently published in the Proxmox APT repository.
#
# Required environment variables:
#
#   PUBLISHED_KERNEL
#       Example: 7.0.14-17
#
#   PUBLISHED_VERSION
#       Example: 7.0.14-17
#
# Outputs written to GITHUB_OUTPUT when available:
#
#   sha
#   subject
#   changelog
#   repository
#
# The repository is intentionally left cloned as:
#
#   proxmox-pve-kernel/
#
# because subsequent workflow steps use that working tree.
#

PVE_DIR="${PVE_DIR:-proxmox-pve-kernel}"

PVE_PRIMARY_REPO="${PVE_PRIMARY_REPO:-https://git.proxmox.com/git/pve-kernel.git}"
PVE_FALLBACK_REPO="${PVE_FALLBACK_REPO:-https://github.com/proxmox/pve-kernel.git}"

PVE_BRANCH="${PVE_BRANCH:-master}"

EXPECTED_SUBJECT="update ABI file for ${PUBLISHED_KERNEL:-UNDEFINED}-pve (amd64)"

RESOLVED_SHA=""
RESOLVED_SUBJECT=""
RESOLVED_CHANGELOG=""
RESOLVED_REPOSITORY=""


#
# Logging helpers
#

log()
{
    printf '%s\n' "$*"
}

warn()
{
    printf 'WARN: %s\n' "$*" >&2
}

error()
{
    printf 'ERROR: %s\n' "$*" >&2
}

die()
{
    error "$*"
    exit 1
}


#
# Validate input
#

if [[ -z "${PUBLISHED_KERNEL:-}" ]]; then
    die "PUBLISHED_KERNEL is not defined"
fi

if [[ -z "${PUBLISHED_VERSION:-}" ]]; then
    die "PUBLISHED_VERSION is not defined"
fi

if [[ "${PUBLISHED_KERNEL}" == *[[:space:]]* ]]; then
    die "invalid PUBLISHED_KERNEL: ${PUBLISHED_KERNEL}"
fi

if [[ "${PUBLISHED_VERSION}" == *[[:space:]]* ]]; then
    die "invalid PUBLISHED_VERSION: ${PUBLISHED_VERSION}"
fi

if [[ -e "${PVE_DIR}" ]]; then
    die "${PVE_DIR} already exists"
fi


#
# Clone a Proxmox source repository.
#
# First try a blob-filtered clone to reduce transfer size.
# If the server does not support partial clones, retry normally.
#

clone_repository()
{
    local repository="$1"
    local label="$2"

    log
    log "============================================================"
    log "Trying Proxmox source repository"
    log "Type:       ${label}"
    log "Repository: ${repository}"
    log "Branch:     ${PVE_BRANCH}"
    log "============================================================"
    log

    rm -rf "${PVE_DIR}"

    if git clone \
        --filter=blob:none \
        --no-checkout \
        --single-branch \
        --branch "${PVE_BRANCH}" \
        "${repository}" \
        "${PVE_DIR}"
    then
        return 0
    fi

    warn "partial clone failed for ${repository}"
    warn "retrying with a regular clone"

    rm -rf "${PVE_DIR}"

    if git clone \
        --no-checkout \
        --single-branch \
        --branch "${PVE_BRANCH}" \
        "${repository}" \
        "${PVE_DIR}"
    then
        return 0
    fi

    warn "unable to clone ${repository}"

    rm -rf "${PVE_DIR}"

    return 1
}


#
# Print useful information when the requested published version cannot
# yet be found in a repository.
#

diagnose_repository_state()
{
    local repository="$1"
    local ref="refs/remotes/origin/${PVE_BRANCH}"

    local tip_sha=""
    local tip_subject=""
    local tip_changelog=""

    tip_sha="$(
        git -C "${PVE_DIR}" \
            rev-parse "${ref}" \
            2>/dev/null ||
        true
    )"

    if [[ -n "${tip_sha}" ]]; then

        tip_subject="$(
            git -C "${PVE_DIR}" \
                show \
                -s \
                --format='%s' \
                "${tip_sha}" \
                2>/dev/null ||
            true
        )"

        tip_changelog="$(
            git -C "${PVE_DIR}" \
                show "${tip_sha}:debian/changelog" \
                2>/dev/null |
            sed -n '1p' ||
            true
        )"
    fi

    log
    warn "published kernel source was not resolved in this repository"
    warn "repository: ${repository}"

    if [[ -n "${tip_sha}" ]]; then
        warn "repository HEAD:      ${tip_sha}"
    fi

    if [[ -n "${tip_subject}" ]]; then
        warn "repository commit:    ${tip_subject}"
    fi

    if [[ -n "${tip_changelog}" ]]; then
        warn "repository changelog: ${tip_changelog}"
    fi

    #
    # Distinguish a repository synchronization delay from a possible
    # change in Proxmox's commit naming convention.
    #

    if [[ -n "${tip_changelog}" ]] &&
       grep -Fq "(${PUBLISHED_VERSION}) " <<< "${tip_changelog}"
    then
        warn
        warn "The repository changelog already contains the published"
        warn "package version, but the expected ABI commit was not found."
        warn
        warn "Expected commit subject:"
        warn "  ${EXPECTED_SUBJECT}"
        warn
        warn "This may indicate that Proxmox changed its ABI commit naming"
        warn "convention. Refusing to guess the source commit."
    else
        warn
        warn "The APT package appears newer than this Git repository."
        warn "This is most likely a publication/synchronization delay."
    fi
}


#
# Search the cloned repository for the exact ABI commit.
#
# We intentionally require:
#
#   1. the exact Proxmox ABI-update commit subject
#   2. a debian/changelog entry matching PUBLISHED_VERSION
#
# This prevents accidentally compiling an older source tree while assigning
# it the version number of a newer published package.
#

resolve_repository()
{
    local repository="$1"
    local ref="refs/remotes/origin/${PVE_BRANCH}"

    local sha=""
    local subject=""
    local changelog=""

    local -a candidates=()

    if ! git -C "${PVE_DIR}" \
        rev-parse \
        --verify \
        "${ref}^{commit}" \
        >/dev/null 2>&1
    then
        warn "branch ${PVE_BRANCH} is not available in ${repository}"
        return 1
    fi

    mapfile -t candidates < <(
        git -C "${PVE_DIR}" \
            log "${ref}" \
            --format='%H%x09%s' |
        awk \
            -F '\t' \
            -v expected="${EXPECTED_SUBJECT}" \
            '$2 == expected { print $1 }'
    )

    if [[ "${#candidates[@]}" -eq 0 ]]; then
        diagnose_repository_state "${repository}"
        return 1
    fi

    #
    # Normally there is exactly one matching commit. We nevertheless
    # inspect every exact-subject candidate and validate its changelog.
    #

    for sha in "${candidates[@]}"; do

        subject="$(
            git -C "${PVE_DIR}" \
                show \
                -s \
                --format='%s' \
                "${sha}"
        )"

        changelog="$(
            git -C "${PVE_DIR}" \
                show "${sha}:debian/changelog" |
            sed -n '1p'
        )"

        if grep -Fq "(${PUBLISHED_VERSION}) " <<< "${changelog}"
        then
            RESOLVED_SHA="${sha}"
            RESOLVED_SUBJECT="${subject}"
            RESOLVED_CHANGELOG="${changelog}"
            RESOLVED_REPOSITORY="${repository}"

            return 0
        fi

        warn "ABI commit candidate rejected"
        warn "SHA:       ${sha}"
        warn "Commit:    ${subject}"
        warn "Changelog: ${changelog}"
        warn "Expected package version: ${PUBLISHED_VERSION}"
    done

    warn
    warn "matching ABI commit subject was found, but none of the"
    warn "candidates matched the published package version"

    return 1
}


#
# Try one repository completely.
#

try_repository()
{
    local repository="$1"
    local label="$2"

    if ! clone_repository "${repository}" "${label}"
    then
        return 1
    fi

    if resolve_repository "${repository}"
    then
        return 0
    fi

    rm -rf "${PVE_DIR}"

    return 1
}


#
# Resolution
#

log "Resolving exact Proxmox source commit"
log
log "Published kernel:  ${PUBLISHED_KERNEL}"
log "Published version: ${PUBLISHED_VERSION}"
log "Expected commit:   ${EXPECTED_SUBJECT}"


#
# 1. Canonical Proxmox Git repository.
#

if try_repository \
    "${PVE_PRIMARY_REPO}" \
    "canonical Proxmox Git"
then
    :
else

    warn
    warn "canonical Proxmox repository did not provide the requested source"
    warn "trying GitHub mirror"

    #
    # 2. GitHub mirror.
    #

    if ! try_repository \
        "${PVE_FALLBACK_REPO}" \
        "GitHub mirror"
    then

        rm -rf "${PVE_DIR}"

        error
        error "unable to resolve the exact source commit for the"
        error "published Proxmox kernel package"
        error
        error "Published kernel:  ${PUBLISHED_KERNEL}"
        error "Published version: ${PUBLISHED_VERSION}"
        error "Expected commit:   ${EXPECTED_SUBJECT}"
        error
        error "Neither the canonical Proxmox Git repository nor the"
        error "GitHub mirror currently contains a source revision that"
        error "can be safely matched to the published package."
        error
        error "Refusing to build ${PUBLISHED_KERNEL}-pve-t2 from an"
        error "older or ambiguous Proxmox source tree."
        error
        error "This is usually temporary when the APT repository is"
        error "published before the Git repositories are synchronized."

        exit 1
    fi
fi


#
# Final integrity checks
#

if [[ -z "${RESOLVED_SHA}" ]]; then
    die "internal error: resolved SHA is empty"
fi

if [[ -z "${RESOLVED_SUBJECT}" ]]; then
    die "internal error: resolved commit subject is empty"
fi

if [[ -z "${RESOLVED_CHANGELOG}" ]]; then
    die "internal error: resolved changelog is empty"
fi

if [[ -z "${RESOLVED_REPOSITORY}" ]]; then
    die "internal error: resolved repository is empty"
fi

if [[ "${RESOLVED_SUBJECT}" != "${EXPECTED_SUBJECT}" ]]; then
    die "resolved source commit subject does not match expected ABI commit"
fi

if ! grep -Fq \
    "(${PUBLISHED_VERSION}) " \
    <<< "${RESOLVED_CHANGELOG}"
then
    die "resolved source does not match published package version"
fi

if ! git -C "${PVE_DIR}" \
    cat-file \
    -e \
    "${RESOLVED_SHA}^{commit}"
then
    die "resolved commit is not present in the cloned repository"
fi


#
# Success
#

log
log "============================================================"
log "Resolved Proxmox source"
log "============================================================"
log "Repository: ${RESOLVED_REPOSITORY}"
log "SHA:        ${RESOLVED_SHA}"
log "Commit:     ${RESOLVED_SUBJECT}"
log "Changelog:  ${RESOLVED_CHANGELOG}"
log "============================================================"


#
# GitHub Actions outputs
#

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then

    {
        echo "sha=${RESOLVED_SHA}"
        echo "subject=${RESOLVED_SUBJECT}"
        echo "changelog=${RESOLVED_CHANGELOG}"
        echo "repository=${RESOLVED_REPOSITORY}"
    } >> "${GITHUB_OUTPUT}"
fi