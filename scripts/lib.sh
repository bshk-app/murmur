#!/usr/bin/env bash
# Shared release helpers. Sourced by scripts/*.sh, never executed: the release
# rules that must not drift between the local run, CI and the checker live here
# exactly once. Every failure path is die(), so callers keep one message format
# and one exit code.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly ZAMOKCTL_MINIMUM=1.3.2

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
require_env() { [[ -n "${!1:-}" ]] || die "$1 is not set; copy .env.example to .env and configure it"; }

reject_unresolved() {
    [[ "${!1:-}" != av://* ]] \
        || die "$1 is still an av:// reference; run through task release or av env"
}

require_semver() {
    [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$1 must be X.Y.Z, got: $2"
}

require_publish_mode() {
    case "$1" in
        0|1) ;;
        *) die "PUBLISH must be 0 or 1, got: $1" ;;
    esac
}

# The marketing version, straight from the committed single source of truth.
read_version() {
    [[ -f "$ROOT/VERSION" ]] || die "VERSION is missing"
    local version
    version="$(tr -d '[:space:]' < "$ROOT/VERSION")"
    require_semver VERSION "$version"
    printf '%s\n' "$version"
}

normalize_channel() {
    local channel
    channel="$(printf '%s' "${1:-stable}" | tr '[:upper:]' '[:lower:]')"
    case "$channel" in
        stable|beta) printf '%s\n' "$channel" ;;
        *) die "RELEASE_CHANNEL must be stable or beta, got: $channel" ;;
    esac
}

# The only place the release tag shape is written down. release-please emits the
# stable form; a channel release adds its own suffix so it can never collide.
release_tag() {
    local version="$1" channel="$2"
    case "$channel" in
        stable) printf 'murmur-v%s\n' "$version" ;;
        *) printf 'murmur-v%s-%s\n' "$version" "$channel" ;;
    esac
}

# Sparkle picks updates by CFBundleVersion, and the shipped 0.1.x used version
# strings while every build from here on is a monotonic integer. The number is
# BUILD_NUMBER_BASE + commit count, so a release built from a clone with a
# shorter history mints a LOWER number than one already published - and an
# installed app then refuses the update forever. Read the published feed and
# refuse before anything is signed.
newest_published_build() {
    sed -n 's#.*<sparkle:version>\([0-9]\{1,\}\)</sparkle:version>.*#\1#p' | sort -n | tail -1
}

assert_build_number_increases() {
    local build="$1" repository="$2" branch="$3" feed newest
    require_command curl
    if ! feed="$(curl -fsSL "https://raw.githubusercontent.com/$repository/$branch/appcast.xml")"; then
        note "note: no published appcast on $branch; skipping the monotonic build check"
        return 0
    fi
    newest="$(printf '%s\n' "$feed" | newest_published_build)"
    if [[ -z "$newest" ]]; then
        note "note: published feed carries no integer build yet; $build is the first"
        return 0
    fi
    [[ "$build" -gt "$newest" ]] \
        || die "build $build does not exceed the published $newest; Sparkle would never offer it. Release from a full clone of $repository."
}

is_github_repository_url() {
    local normalized="${1%.git}" repository="$2"
    case "$normalized" in
        "git@github.com:$repository"|"ssh://git@github.com/$repository"|"https://github.com/$repository"|"http://github.com/$repository")
            return 0
            ;;
        *) return 1 ;;
    esac
}

verify_github_release_asset() {
    local repository="$1" tag="$2" file="$3" name digest local_sha work downloaded
    require_command gh
    require_command shasum
    require_command cmp
    [[ -f "$file" ]] || die "release artifact is missing: $file"
    name="$(basename "$file")"
    digest="$(gh api "repos/$repository/releases/tags/$tag" \
        --jq ".assets[] | select(.name == \"$name\") | .digest")" \
        || die "could not inspect $tag assets in $repository"
    [[ -n "$digest" ]] || die "$tag has no $name asset"
    local_sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    if [[ "$digest" == sha256:* ]]; then
        [[ "$digest" == "sha256:$local_sha" ]] \
            || die "$file does not match the immutable GitHub asset $tag/$name"
        return
    fi

    # Older GitHub releases may not expose asset digests. Download and compare
    # bytes rather than trusting a same-version local rebuild.
    work="$(mktemp -d)"
    downloaded="$work/$name"
    if ! gh release download "$tag" --repo "$repository" --pattern "$name" --dir "$work"; then
        rm -rf "$work"
        die "could not download $tag/$name for verification"
    fi
    if ! cmp -s "$file" "$downloaded"; then
        rm -rf "$work"
        die "$file does not match the immutable GitHub asset $tag/$name"
    fi
    rm -rf "$work"
}

# GitHub's repository permission field describes the user role, not the actual
# token scope. A create/delete probe is the only reliable preflight for a
# fine-grained token's Contents:write grant; it runs before any release mutation.
verify_github_repo_write() (
    local token="$1" repository="$2" default_branch sha ref endpoint created=false
    require_command gh
    # Both codes describe the same fact: the trap calls this, not the script.
    # shellcheck disable=SC2329,SC2317
    cleanup_probe() {
        if [[ "$created" == "true" ]]; then
            GH_TOKEN="$token" gh api --method DELETE \
                "repos/$repository/git/refs/$endpoint" --silent >/dev/null 2>&1 || true
        fi
    }
    trap cleanup_probe EXIT INT TERM

    default_branch="$(GH_TOKEN="$token" gh api "repos/$repository" --jq .default_branch)" \
        || die "could not read $repository with TAP_GITHUB_TOKEN"
    sha="$(GH_TOKEN="$token" gh api "repos/$repository/git/ref/heads/$default_branch" --jq .object.sha)" \
        || die "could not resolve $repository/$default_branch with TAP_GITHUB_TOKEN"
    ref="refs/heads/release-preflight/$(date +%s)-$$-$RANDOM"
    endpoint="${ref#refs/}"
    GH_TOKEN="$token" gh api --method POST "repos/$repository/git/refs" \
        -f ref="$ref" -f sha="$sha" --silent \
        || die "TAP_GITHUB_TOKEN cannot create a temporary ref in $repository"
    created=true
    GH_TOKEN="$token" gh api --method DELETE "repos/$repository/git/refs/$endpoint" --silent \
        || die "TAP_GITHUB_TOKEN created $ref but could not delete it"
    created=false
    trap - EXIT INT TERM
)

require_zamokctl() {
    require_command zamokctl
    local have
    have="$(zamokctl --version 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$have" ]] || die "could not read zamokctl --version"
    [[ "$(printf '%s\n%s\n' "$ZAMOKCTL_MINIMUM" "$have" | sort -V | head -1)" == "$ZAMOKCTL_MINIMUM" ]] \
        || die "zamokctl $have is too old; need >= $ZAMOKCTL_MINIMUM"
}

# Nothing ships from a tree a reviewer cannot fetch from the remote.
require_clean_pushed_tree() {
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
        || die "working tree is dirty; commit the release inputs first"
    local upstream
    if upstream="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
        [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse "$upstream")" ]] \
            || die "HEAD is not pushed to $upstream"
    elif git -C "$ROOT" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
        die "current branch has no upstream"
    fi
}
