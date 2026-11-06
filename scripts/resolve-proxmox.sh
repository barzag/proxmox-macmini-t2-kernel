#!/usr/bin/env bash
# Resolve the Proxmox Git source revision for the APT-published kernel.
# Prefer the historical ABI update commit; accept a strictly verified
# version-bump commit when Proxmox publishes without a separate ABI commit.
set -Eeuo pipefail
export LC_ALL=C

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

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in git dpkg sed awk; do
    command -v "$tool" >/dev/null 2>&1 || die "missing dependency: $tool"
done

[[ -n "${PUBLISHED_KERNEL:-}" && -n "${PUBLISHED_VERSION:-}" ]] ||
    die "PUBLISHED_KERNEL and PUBLISHED_VERSION are required"
[[ "$PUBLISHED_KERNEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] ||
    die "unsupported kernel identifier: $PUBLISHED_KERNEL"
[[ "$PUBLISHED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] ||
    die "unsupported package version: $PUBLISHED_VERSION"
[[ "$PUBLISHED_KERNEL" == "$PUBLISHED_VERSION" ]] ||
    die "published kernel and package version disagree"
[[ ! -e "$PVE_DIR" ]] || die "destination already exists: $PVE_DIR"

EXPECTED_ABI="update ABI file for ${PUBLISHED_KERNEL}-pve (amd64)"
EXPECTED_BUMP="bump version to ${PUBLISHED_VERSION}"

changelog_version() {
    sed -nE 's/^[^[:space:]]+[[:space:]]+\(([^)]+)\).*/\1/p' <<< "$1"
}

# Read a literal Makefile assignment (do not evaluate arbitrary Makefile code).
make_value() {
    local key="$1" data="$2"
    sed -nE "s/^${key}[[:space:]]*=[[:space:]]*([^#]*).*$/\\1/p" <<< "$data" |
        sed -E 's/[[:space:]]+$//;s/^[[:space:]]+//'
}

# Both supported commit types must describe the exact published release.
# The fallback additionally verifies the complete Makefile kernel identity.
validate_candidate() {
    local sha="$1" subject="$2"
    local line version makefile maj min patch rel rel_extra pkg_extra

    line="$(git -C "$PVE_DIR" show "${sha}:debian/changelog" 2>/dev/null | sed -n '1p')" || return 1
    version="$(changelog_version "$line")"
    [[ "$version" == "$PUBLISHED_VERSION" ]] || return 1

    makefile="$(git -C "$PVE_DIR" show "${sha}:Makefile" 2>/dev/null)" || return 1
    maj="$(make_value KERNEL_MAJ "$makefile")"
    min="$(make_value KERNEL_MIN "$makefile")"
    patch="$(make_value KERNEL_PATCHLEVEL "$makefile")"
    rel="$(make_value KREL "$makefile")"
    rel_extra="$(make_value KREL_EXTRA "$makefile")"
    pkg_extra="$(make_value PKG_REV_EXTRA "$makefile")"

    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ &&
       "$patch" =~ ^[0-9]+$ && "$rel" =~ ^[0-9]+$ ]] || return 1
    [[ -z "$rel_extra" && -z "$pkg_extra" ]] || return 1
    [[ "${maj}.${min}.${patch}-${rel}" == "$PUBLISHED_KERNEL" ]] || return 1
    [[ "$line" == "proxmox-kernel-${maj}.${min} (${PUBLISHED_VERSION}) "* ]] || return 1
    [[ "$subject" == "$EXPECTED_ABI" || "$subject" == "$EXPECTED_BUMP" ]] || return 1

    RESOLVED_SHA="$sha"
    RESOLVED_SUBJECT="$subject"
    RESOLVED_CHANGELOG="$line"
    return 0
}

clone_repository() {
    local url="$1" label="$2"
    log "Trying ${label}: ${url} (${PVE_BRANCH})"
    rm -rf -- "$PVE_DIR"
    if [[ "$url" == "$PVE_PRIMARY_REPO" ]]; then
        git clone --no-checkout --single-branch --branch "$PVE_BRANCH" \
            "$url" "$PVE_DIR" && return 0
    else
        git clone --filter=blob:none --no-checkout --single-branch \
            --branch "$PVE_BRANCH" "$url" "$PVE_DIR" && return 0
        rm -rf -- "$PVE_DIR"
        git clone --no-checkout --single-branch --branch "$PVE_BRANCH" \
            "$url" "$PVE_DIR" && return 0
    fi
    rm -rf -- "$PVE_DIR"
    warn "clone failed: ${url}"
    return "$RESOLVE_ERROR"
}

resolve_repository() {
    local url="$1" ref="refs/remotes/origin/${PVE_BRANCH}"
    local sha subject line tip_version tip_sha candidate history
    local -a matches=()

    git -C "$PVE_DIR" rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1 ||
        return "$RESOLVE_ERROR"

    # Search the full branch history, not just HEAD. Prefer ABI commits.
    # If an ABI commit exists but is invalid, do NOT silently fall back.
    history="$(git -C "$PVE_DIR" log "$ref" --format='%H%x09%s')" ||
        return "$RESOLVE_ERROR"
    mapfile -t matches < <(
        awk -F '\t' -v wanted="$EXPECTED_ABI" '$2 == wanted {print $1}'             <<< "$history"
    )
    if ((${#matches[@]} > 0)); then
        subject="$EXPECTED_ABI"
    else
        mapfile -t matches < <(
            awk -F '\t' -v wanted="$EXPECTED_BUMP" '$2 == wanted {print $1}'                 <<< "$history"
        )
        subject="$EXPECTED_BUMP"
    fi

    # Multiple identically titled release commits are ambiguous: do not
    # silently choose an older one if a newer candidate fails validation.
    if ((${#matches[@]} > 1)); then
        LAST_REPOSITORY_STATE=mismatch
        warn "ambiguous release history: ${#matches[@]} commits have subject '$subject'"
        return "$RESOLVE_MISMATCH"
    fi

    if ((${#matches[@]} > 0)); then
        for candidate in "${matches[@]}"; do
            if validate_candidate "$candidate" "$subject"; then
                RESOLVED_REPOSITORY="$url"
                LAST_REPOSITORY_STATE=resolved
                return "$RESOLVE_OK"
            fi
            warn "release candidate rejected after metadata checks: $candidate ($subject)"
        done
        LAST_REPOSITORY_STATE=mismatch
        return "$RESOLVE_MISMATCH"
    fi

    tip_sha="$(git -C "$PVE_DIR" rev-parse "$ref")" || return "$RESOLVE_ERROR"
    line="$(git -C "$PVE_DIR" show "${tip_sha}:debian/changelog" 2>/dev/null | sed -n '1p')" ||
        return "$RESOLVE_ERROR"
    tip_version="$(changelog_version "$line")"
    [[ -n "$tip_version" ]] || return "$RESOLVE_ERROR"
    LAST_REPOSITORY_VERSION="$tip_version"

    if dpkg --compare-versions "$tip_version" lt "$PUBLISHED_VERSION"; then
        LAST_REPOSITORY_STATE=pending
        warn "Git source $tip_version is older than published APT $PUBLISHED_VERSION"
        return "$RESOLVE_PENDING"
    fi
    LAST_REPOSITORY_STATE=mismatch
    warn "no exact release commit found; Git source version: $tip_version"
    return "$RESOLVE_MISMATCH"
}

try_repository() {
    local url="$1" label="$2" rc=0
    LAST_REPOSITORY_STATE=""
    LAST_REPOSITORY_VERSION=""
    clone_repository "$url" "$label" || return $?
    resolve_repository "$url" || rc=$?
    if ((rc != RESOLVE_OK)); then
        rm -rf -- "$PVE_DIR"
    fi
    return "$rc"
}

write_outputs() {
    local status="$1"
    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
    {
        printf 'status=%s\n' "$status"
        printf 'sha=%s\n' "$RESOLVED_SHA"
        printf 'subject=%s\n' "$RESOLVED_SUBJECT"
        printf 'changelog=%s\n' "$RESOLVED_CHANGELOG"
        printf 'repository=%s\n' "$RESOLVED_REPOSITORY"
    } >> "$GITHUB_OUTPUT"
}

log "Resolving published Proxmox source: $PUBLISHED_VERSION"
log "Preferred: $EXPECTED_ABI"
log "Fallback:  $EXPECTED_BUMP"

primary_rc="$RESOLVE_ERROR"
fallback_rc="$RESOLVE_ERROR"
if try_repository "$PVE_PRIMARY_REPO" 'canonical Proxmox Git'; then
    primary_rc="$RESOLVE_OK"
else
    primary_rc=$?
    warn "canonical repository did not resolve; trying GitHub mirror"
    if try_repository "$PVE_FALLBACK_REPO" 'GitHub mirror'; then
        fallback_rc="$RESOLVE_OK"
    else
        fallback_rc=$?
    fi
fi

if [[ -n "$RESOLVED_SHA" ]]; then
    git -C "$PVE_DIR" cat-file -e "${RESOLVED_SHA}^{commit}" ||
        die "resolved commit is missing from clone"
    [[ -n "$RESOLVED_REPOSITORY" && -n "$RESOLVED_CHANGELOG" ]] ||
        die "incomplete resolved source metadata"
    log "Resolved: $RESOLVED_SHA"
    log "Commit:   $RESOLVED_SUBJECT"
    log "Source:   $RESOLVED_REPOSITORY"
    write_outputs resolved
    exit 0
fi

# Only a provably older Git version counts as publication delay.
# Any repository with a conflicting release state remains a hard failure.
if ((primary_rc != RESOLVE_MISMATCH && fallback_rc != RESOLVE_MISMATCH)) &&
   ((primary_rc == RESOLVE_PENDING || fallback_rc == RESOLVE_PENDING)); then
    log "Proxmox source pending publication; T2 build skipped safely"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo '## Proxmox source pending'
            echo
            echo "- Published kernel: \`$PUBLISHED_KERNEL\`"
            echo "- Published version: \`$PUBLISHED_VERSION\`"
            echo '- Source status: **pending publication**'
            echo
            echo 'Matching source revision is not yet available; build skipped.'
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    write_outputs pending
    exit 0
fi

die "unable to resolve exact Proxmox source safely (primary=$primary_rc, fallback=$fallback_rc; expected '$EXPECTED_ABI' or '$EXPECTED_BUMP')"
