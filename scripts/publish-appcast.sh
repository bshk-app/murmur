#!/usr/bin/env bash
set -euo pipefail

# Compatibility-first feed publisher. Murmur 0.1.1 is permanently baked with
# raw.githubusercontent.com/bshk-app/murmur/main/appcast.xml, so the 0.2 release
# must update that path. A later release can migrate new clients to gh-pages once
# this bridge release has reached the installed base.

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly USAGE='usage: publish-appcast.sh DMG SHORT_VERSION TAG [NOTES.md]'
readonly DMG="${1:?$USAGE}"
readonly SHORT_VERSION="${2:?$USAGE}"
readonly TAG="${3:?$USAGE}"
readonly NOTES_MD="${4:-}"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/murmur}"
readonly FEED_BRANCH="${APPCAST_BRANCH:-main}"
APPCAST_REMOTE="${APPCAST_GIT_REMOTE:-}"
if [[ -z "$APPCAST_REMOTE" ]]; then
    if git -C "$ROOT" remote get-url github >/dev/null 2>&1; then
        APPCAST_REMOTE=github
    else
        APPCAST_REMOTE=origin
    fi
fi
readonly APPCAST_REMOTE
remote_url="$(git -C "$ROOT" remote get-url "$APPCAST_REMOTE" 2>/dev/null)" \
    || die "git remote '$APPCAST_REMOTE' does not exist"
push_url="$(git -C "$ROOT" remote get-url --push "$APPCAST_REMOTE" 2>/dev/null)" \
    || die "git remote '$APPCAST_REMOTE' has no push URL"
is_github_repository_url "$remote_url" "$REPOSITORY" \
    || die "fetch URL for '$APPCAST_REMOTE' is not GitHub repository $REPOSITORY: $remote_url"
is_github_repository_url "$push_url" "$REPOSITORY" \
    || die "push URL for '$APPCAST_REMOTE' is not GitHub repository $REPOSITORY: $push_url"

require_zamokctl
require_command gh
require_command jq
require_command xmllint
require_env SPARKLE_PUBLIC_ED_KEY
[[ -f "$DMG" ]] || die "no DMG at $DMG"
reject_unresolved SPARKLE_PRIVATE_ED_KEY
require_semver SHORT_VERSION "$SHORT_VERSION"
expected_tag="$(release_tag "$SHORT_VERSION" stable)"
[[ "$TAG" == "$expected_tag" ]] \
    || die "stable appcast requires tag $expected_tag, got: $TAG"
verify_github_release_asset "$REPOSITORY" "$TAG" "$DMG"

sparkle_bin="${SPARKLE_BIN:-$(
    for caskroom in /opt/homebrew/Caskroom/sparkle /usr/local/Caskroom/sparkle; do
        [[ -d "$caskroom" ]] || continue
        find "$caskroom" -maxdepth 3 -name sign_update -type f -print
    done | sort -V | tail -1 | xargs dirname
)}"
[[ -x "$sparkle_bin/generate_keys" && -x "$sparkle_bin/sign_update" ]] \
    || die "Sparkle generate_keys/sign_update tools are missing"

work="$(umask 077; mktemp -d)"
worktree="$work/feed"
cleanup() {
    if [[ -f "$work/ed-key" ]]; then rm -P "$work/ed-key" 2>/dev/null || rm -f "$work/ed-key"; fi
    git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

"$ROOT/scripts/export-sparkle-key.sh" "$work/ed-key"

notes_args=()
if [[ -n "$NOTES_MD" ]]; then
    [[ -s "$NOTES_MD" ]] || die "release notes file is empty: $NOTES_MD"
    jq -n --arg text "$(cat "$NOTES_MD")" '{mode:"gfm",text:$text}' \
        | gh api -X POST /markdown --input - > "$work/notes.html" \
        || die "could not render release notes to HTML"
    [[ -s "$work/notes.html" ]] || die "rendered release notes are empty"
    notes_args=(--release-notes "$work/notes.html")
else
    note "note: no release notes given — the update panel will be empty"
fi

git -C "$ROOT" fetch --quiet "$APPCAST_REMOTE" "$FEED_BRANCH" \
    || die "could not fetch $APPCAST_REMOTE/$FEED_BRANCH"
git -C "$ROOT" worktree add --quiet --detach "$worktree" "$APPCAST_REMOTE/$FEED_BRANCH"

feed="$worktree/appcast.xml"
note "== signing $(basename "$DMG") into ${FEED_BRANCH}/appcast.xml =="
zamokctl appcast \
    --input "$DMG" \
    --ed-key-file "$work/ed-key" \
    --download-url-prefix "https://github.com/${REPOSITORY}/releases/download/${TAG}/" \
    --appcast "$feed" \
    "${notes_args[@]}" \
    --maximum-versions 10
[[ -f "$feed" ]] || die "zamokctl appcast wrote no feed"
signature="$(
    xmllint --xpath \
        "string(//*[local-name()='enclosure' and contains(@url, '/${TAG}/')]/@*[local-name()='edSignature'])" \
        "$feed"
)"
[[ -n "$signature" ]] || die "the new $TAG enclosure has no EdDSA signature"
"$sparkle_bin/sign_update" --verify --ed-key-file "$work/ed-key" "$DMG" "$signature" \
    || die "the new $TAG enclosure signature does not verify"

git -C "$worktree" add appcast.xml
if git -C "$worktree" diff --cached --quiet -- appcast.xml; then
    note "feed already current; nothing to publish"
    exit 0
fi
git -C "$worktree" -c commit.gpgsign=false \
    -c "user.name=${GIT_AUTHOR_NAME:-release}" \
    -c "user.email=${GIT_AUTHOR_EMAIL:-release@users.noreply.github.com}" \
    commit --quiet -m "release: update Sparkle appcast for murmur-v${SHORT_VERSION}"
git -C "$worktree" push --quiet "$APPCAST_REMOTE" "HEAD:refs/heads/${FEED_BRANCH}"

printf 'Feed: https://raw.githubusercontent.com/%s/%s/appcast.xml\n' \
    "$REPOSITORY" "$FEED_BRANCH"
