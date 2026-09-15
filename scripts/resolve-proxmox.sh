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
# GitHub Actions outputs:
#
#   status      resolved | pending
#   sha         exact Proxmox source commit (empty when pending)
#   subject     exact commit subject (empty when pending)
#   changelog   first debian/changelog line (empty when pending)
#   repository  repository used for resolution (empty when pending)
#
# Exit policy:
#
#   0  resolved successfully OR genuine publication delay ("pending")
#   1  unsafe mismatch, repository failure, invalid input, or internal error
#
# A pending source is intentionally NOT treated as a workflow error:
# the scheduled workflow can retry later without creating a false red failure.
#

PVE_DIR="${PVE_DIR:-proxmox-pve-kernel}"

PVE_PRIMARY_REPO="${PVE_PRIMARY_REPO:-https://git.proxmox.com/git/pve-kernel.git}"
PVE_FALLBACK_REPO="${PVE_FALLBACK_REPO:-https://github.com/proxmox/pve-kernel.git}"

PVE_BRANCH="${PVE_BRANCH:-master}"

RESOLVE_OK=0
RESOLVE_PENDING=10
RESOLVE_MISMATCH=20
RESOLVE_ERROR=30

RESOLVED_SHA=""
RESOLVED_SUBJECT=""
RESOLVED_CHANGELOG=""
RESOLVED_REPOSITORY=""

LAST_REPOSITORY_STATE=""
LAST_REPOSITORY_VERSION=""

EXPECTED_SUBJECT=""


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
# GitHub Actions helpers
#

write_outputs_resolved()
{
    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0

    {
        echo "status=resolved"
        echo "sha=${RESOLVED_SHA}"
        echo "subject=${RESOLVED_SUBJECT}"
        echo "changelog=${RESOLVED_CHANGELOG}"
        echo "repository=${RESOLVED_REPOSITORY}"
    } >> "${GITHUB_OUTPUT}"
}

write_outputs_pending()
{
    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0

    {
        echo "status=pending"
        echo "sha="
        echo "subject="
        echo "changelog="
        echo "repository="
    } >> "${GITHUB_OUTPUT}"
}

write_pending_summary()
{
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0

    {
        echo "## Proxmox source pending"
        echo
        echo "- Published kernel: \`${PUBLISHED_KERNEL}\`"
        echo "- Published version: \`${PUBLISHED_VERSION}\`"
        echo "- Source status: **pending publication**"
        echo
        echo "The binary package is already available in the Proxmox APT repository,"
        echo "but the exact matching source revision is not yet available from the"
        echo "Proxmox Git repositories."
        echo
        echo "The T2 build was intentionally skipped. A later scheduled run will retry."
    } >> "${GITHUB_STEP_SUMMARY}"
}


#
# Validate prerequisites and input
#

command -v git >/dev/null 2>&1 || die "git is not available"
command -v dpkg >/dev/null 2>&1 || die "dpkg is not available"

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

EXPECTED_SUBJECT="update ABI file for ${PUBLISHED_KERNEL}-pve (amd64)"


#
# Clone one Proxmox source repository.
#
# git.proxmox.com currently does not necessarily support partial-clone
# filtering, so use a normal no-checkout clone there.
#
# The GitHub mirror supports blob filtering, which reduces transfer size.
# If filtered cloning fails, retry it as a normal clone.
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

    if [[ "${repository}" == "${PVE_PRIMARY_REPO}" ]]; then
        if git clone \
            --no-checkout \
            --single-branch \
            --branch "${PVE_BRANCH}" \
            "${repository}" \
            "${PVE_DIR}"
        then
            return 0
        fi

        warn "unable to clone canonical repository: ${repository}"
        rm -rf "${PVE_DIR}"
        return "${RESOLVE_ERROR}"
    fi

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

    return "${RESOLVE_ERROR}"
}


#
# Read the package version from the first line of debian/changelog.
#
# Example:
#
#   proxmox-kernel-7.0 (7.0.14-16) trixie; urgency=medium
#
# becomes:
#
#   7.0.14-16
#

extract_changelog_version()
{
    local changelog_line="$1"

    sed -nE 's/^[^[:space:]]+[[:space:]]+\(([^)]+)\).*/\1/p' \
        <<< "${changelog_line}"
}


#
# Diagnose a repository that does not contain the expected ABI commit.
#
# Classification is deliberately strict:
#
#   pending:
#       repository package version < published APT version
#
#   mismatch:
#       repository version == published version but expected ABI commit missing,
#       or repository version > published version
#
#   error:
#       repository state cannot be proved safely
#

diagnose_repository_state()
{
    local repository="$1"
    local ref="refs/remotes/origin/${PVE_BRANCH}"

    local tip_sha=""
    local tip_subject=""
    local tip_changelog=""
    local tip_version=""

    LAST_REPOSITORY_STATE=""
    LAST_REPOSITORY_VERSION=""

    tip_sha="$(
        git -C "${PVE_DIR}" \
            rev-parse "${ref}" \
            2>/dev/null ||
        true
    )"

    if [[ -z "${tip_sha}" ]]; then
        LAST_REPOSITORY_STATE="error"
        warn "unable to determine repository HEAD for ${repository}"
        return "${RESOLVE_ERROR}"
    fi

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

    tip_version="$(extract_changelog_version "${tip_changelog}")"

    log
    warn "published kernel source was not resolved in this repository"
    warn "repository: ${repository}"
    warn "repository HEAD:      ${tip_sha}"

    if [[ -n "${tip_subject}" ]]; then
        warn "repository commit:    ${tip_subject}"
    fi

    if [[ -n "${tip_changelog}" ]]; then
        warn "repository changelog: ${tip_changelog}"
    fi

    if [[ -z "${tip_version}" ]]; then
        LAST_REPOSITORY_STATE="error"

        warn
        warn "Unable to determine the package version from debian/changelog."
        warn "Refusing to classify this repository as merely pending."

        return "${RESOLVE_ERROR}"
    fi

    LAST_REPOSITORY_VERSION="${tip_version}"

    if dpkg --compare-versions "${tip_version}" lt "${PUBLISHED_VERSION}"; then
        LAST_REPOSITORY_STATE="pending"

        warn
        warn "The APT package is newer than this Git repository."
        warn "Git version: ${tip_version}"
        warn "APT version: ${PUBLISHED_VERSION}"
        warn "This is treated as a publication/synchronization delay."

        return "${RESOLVE_PENDING}"
    fi

    LAST_REPOSITORY_STATE="mismatch"

    if dpkg --compare-versions "${tip_version}" eq "${PUBLISHED_VERSION}"; then
        warn
        warn "The repository changelog already matches the published package"
        warn "version, but the expected ABI commit was not found."
        warn
        warn "Expected commit subject:"
        warn "  ${EXPECTED_SUBJECT}"
        warn
        warn "This may indicate a change in Proxmox's commit naming or source"
        warn "layout. Refusing to guess the source commit."
    else
        warn
        warn "The repository is newer than the published package, but the exact"
        warn "expected ABI commit could not be resolved."
        warn "Git version: ${tip_version}"
        warn "APT version: ${PUBLISHED_VERSION}"
        warn "Refusing to guess or build from an ambiguous source revision."
    fi

    return "${RESOLVE_MISMATCH}"
}


#
# Search a cloned repository for the exact ABI commit.
#
# We require both:
#
#   1. exact commit subject
#   2. exact package version in debian/changelog at that commit
#
# This prevents an older Proxmox source tree from being labelled as a newer
# published kernel.
#

resolve_repository()
{
    local repository="$1"
    local ref="refs/remotes/origin/${PVE_BRANCH}"

    local sha=""
    local subject=""
    local changelog=""
    local changelog_version=""

    local -a candidates=()

    if ! git -C "${PVE_DIR}" \
        rev-parse \
        --verify \
        "${ref}^{commit}" \
        >/dev/null 2>&1
    then
        LAST_REPOSITORY_STATE="error"
        warn "branch ${PVE_BRANCH} is not available in ${repository}"
        return "${RESOLVE_ERROR}"
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
        local diagnostic_rc=0

        diagnose_repository_state "${repository}" || diagnostic_rc=$?

        return "${diagnostic_rc}"
    fi

    #
    # There should normally be exactly one candidate, but validate every
    # exact-subject match rather than assuming uniqueness.
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

        changelog_version="$(extract_changelog_version "${changelog}")"

        if [[ -n "${changelog_version}" ]] &&
           dpkg --compare-versions "${changelog_version}" eq "${PUBLISHED_VERSION}"
        then
            RESOLVED_SHA="${sha}"
            RESOLVED_SUBJECT="${subject}"
            RESOLVED_CHANGELOG="${changelog}"
            RESOLVED_REPOSITORY="${repository}"
            LAST_REPOSITORY_STATE="resolved"
            LAST_REPOSITORY_VERSION="${changelog_version}"

            return "${RESOLVE_OK}"
        fi

        warn "ABI commit candidate rejected"
        warn "SHA:       ${sha}"
        warn "Commit:    ${subject}"
        warn "Changelog: ${changelog}"
        warn "Expected package version: ${PUBLISHED_VERSION}"
    done

    LAST_REPOSITORY_STATE="mismatch"

    warn
    warn "The expected ABI commit subject was found, but none of its"
    warn "candidates matched the published package version."
    warn "Refusing to select an ambiguous source commit."

    return "${RESOLVE_MISMATCH}"
}


#
# Try one repository completely.
#

try_repository()
{
    local repository="$1"
    local label="$2"
    local rc=0

    LAST_REPOSITORY_STATE=""
    LAST_REPOSITORY_VERSION=""

    clone_repository "${repository}" "${label}" || rc=$?

    if [[ "${rc}" -ne 0 ]]; then
        return "${rc}"
    fi

    resolve_repository "${repository}" || rc=$?

    if [[ "${rc}" -eq "${RESOLVE_OK}" ]]; then
        return "${RESOLVE_OK}"
    fi

    rm -rf "${PVE_DIR}"

    return "${rc}"
}


#
# Resolution
#

log "Resolving exact Proxmox source commit"
log
log "Published kernel:  ${PUBLISHED_KERNEL}"
log "Published version: ${PUBLISHED_VERSION}"
log "Expected commit:   ${EXPECTED_SUBJECT}"

PRIMARY_RC="${RESOLVE_ERROR}"
FALLBACK_RC="${RESOLVE_ERROR}"


#
# 1. Canonical Proxmox Git repository.
#

if try_repository \
    "${PVE_PRIMARY_REPO}" \
    "canonical Proxmox Git"
then
    PRIMARY_RC="${RESOLVE_OK}"
else
    PRIMARY_RC=$?

    warn
    warn "canonical Proxmox repository did not provide the requested source"
    warn "trying GitHub mirror"

    #
    # 2. GitHub mirror.
    #

    if try_repository \
        "${PVE_FALLBACK_REPO}" \
        "GitHub mirror"
    then
        FALLBACK_RC="${RESOLVE_OK}"
    else
        FALLBACK_RC=$?

        rm -rf "${PVE_DIR}"

        #
        # A clean skip is allowed only if at least one repository proves that
        # its source version is older than the APT-published package, and no
        # repository reports an unsafe mismatch.
        #

        if [[ "${PRIMARY_RC}" -ne "${RESOLVE_MISMATCH}" ]] &&
           [[ "${FALLBACK_RC}" -ne "${RESOLVE_MISMATCH}" ]] &&
           { [[ "${PRIMARY_RC}" -eq "${RESOLVE_PENDING}" ]] ||
             [[ "${FALLBACK_RC}" -eq "${RESOLVE_PENDING}" ]]; }
        then
            log
            log "============================================================"
            log "Proxmox source publication pending"
            log "============================================================"
            log "Published kernel:  ${PUBLISHED_KERNEL}"
            log "Published version: ${PUBLISHED_VERSION}"
            log
            log "The binary package is already available, but the exact"
            log "matching Proxmox Git source has not been published yet."
            log
            log "T2 compilation will be skipped for this workflow run."
            log "The scheduled workflow can retry automatically later."
            log "============================================================"

            write_outputs_pending
            write_pending_summary

            exit 0
        fi

        error
        error "unable to resolve the exact source commit safely"
        error
        error "Published kernel:  ${PUBLISHED_KERNEL}"
        error "Published version: ${PUBLISHED_VERSION}"
        error "Expected commit:   ${EXPECTED_SUBJECT}"
        error
        error "Primary resolver status:  ${PRIMARY_RC}"
        error "Fallback resolver status: ${FALLBACK_RC}"
        error
        error "This is not considered a safe publication-delay condition."
        error "Refusing to continue."

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

RESOLVED_CHANGELOG_VERSION="$(
    extract_changelog_version "${RESOLVED_CHANGELOG}"
)"

if [[ -z "${RESOLVED_CHANGELOG_VERSION}" ]] ||
   ! dpkg --compare-versions \
       "${RESOLVED_CHANGELOG_VERSION}" \
       eq \
       "${PUBLISHED_VERSION}"
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
log "Status:     resolved"
log "============================================================"

write_outputs_resolved