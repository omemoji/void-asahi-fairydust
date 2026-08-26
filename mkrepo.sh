#!/bin/sh
# Build linux-asahi-fairydust against a pinned void-packages revision, sign an
# xbps binary repository under ./dist/<arch>/, and (optionally) publish it to the
# orphan branch "repository-<arch>", served to users via raw.githubusercontent.
#
# The -dbg package is intentionally NOT distributed (the official Void repos
# don't ship debug packages in the main repository either).
#
# Usage:
#   ./mkrepo.sh [build]      # build + sign into ./dist/aarch64 only (default)
#   ./mkrepo.sh publish      # push an already-built ./dist/aarch64 to the branch
#   ./mkrepo.sh all          # build, then publish
#
# The two halves are separate so a build can be test-installed locally before it
# is published, and then published without rebuilding or re-signing anything:
#
#   ./mkrepo.sh
#   sudo xbps-install --repository=<repo>/dist/aarch64 linux-asahi-fairydust
#   ...reboot, try it...
#   ./mkrepo.sh publish
#
# PUBLISH=1 is still honoured for compatibility and means the same as "all".
#
# Overridable via environment:
#   VOIDPKGS   path to the void-packages checkout (default: ~/github/omemoji/void-packages)
#   KEYDIR     dir holding privkey.pem            (default: ~/.config/void-asahi-fairydust)
#   SIGNEDBY   signature identity string
#   XBPS_PASSPHRASE  passphrase for the (encrypted) signing key; prompted if unset
#   VOIDREF    void-packages revision to build against (default: upstream/master)
#   FETCH=0    do not fetch that ref's remote first; use the ref as it stands
#   GENFROM    generate the template from a different revision than VOIDREF
#              (default: VOIDREF); passed to gen.sh --from
#   SKIP_GEN=1 build srcpkg/ as committed, without regenerating from upstream
#   REUSE_BINPKG=1  pass -e to xbps-src: if a binary package for this exact
#              version/revision already exists locally, do not rebuild it
set -eu

VOIDPKGS="${VOIDPKGS:-$HOME/github/omemoji/void-packages}"
KEYDIR="${KEYDIR:-$HOME/.config/void-asahi-fairydust}"
PRIVKEY="$KEYDIR/privkey.pem"
SIGNEDBY="${SIGNEDBY:-omemoji <me@omemoji.com>}"

PKG=linux-asahi-fairydust
ARCH=aarch64
BRANCH="repository-$ARCH"
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
DIST="$HERE/dist/$ARCH"

# Everything temporary is torn down through one handler: a second "trap ... EXIT"
# elsewhere would silently replace the first and leak a worktree.
WORKTREE=""
PUBTMP=""
cleanup() {
	if [ -n "$PUBTMP" ]; then rm -rf "$PUBTMP"; PUBTMP=""; fi
	if [ -n "$WORKTREE" ]; then
		git -C "$VOIDPKGS" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
		WORKTREE=""
	fi
	:   # must not leave a failed test as the handler's exit status
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- mode ------------------------------------------------------------------
MODE="${1:-build}"
case "$MODE" in
build|publish|all) ;;
*) echo "usage: ${0##*/} [build|publish|all]" >&2; exit 1 ;;
esac
# PUBLISH=1 predates the subcommands and used to mean "build, then publish".
if [ "${PUBLISH:-0}" = 1 ] && [ "$MODE" = build ]; then
	MODE=all
fi

# --- publish ---------------------------------------------------------------
# Force-push $DIST to the orphan branch, in a throwaway clone so the working
# tree/branch you are on is untouched. The branch is recreated from scratch each
# time (single commit, no history bloat from large binaries). Nothing here
# rebuilds or re-signs: it ships exactly the bytes that are already in $DIST.
do_publish() {
	# Refuse to publish a repository that is not a complete, signed one -- a
	# missing signature only shows up as a failed install on a user's machine.
	[ -d "$DIST" ] || { echo "error: $DIST does not exist; run '${0##*/} build' first" >&2; exit 1; }
	[ -f "$DIST/$ARCH-repodata" ] || { echo "error: $DIST/$ARCH-repodata missing (repository not indexed/signed)" >&2; exit 1; }
	set -- "$DIST"/*.xbps
	[ -f "$1" ] || { echo "error: no .xbps packages in $DIST" >&2; exit 1; }
	for f in "$@"; do
		[ -f "$f.sig2" ] || { echo "error: unsigned package: $f (no $f.sig2)" >&2; exit 1; }
	done

	remote=$(git -C "$HERE" remote get-url origin)
	PUBTMP=$(mktemp -d)
	echo ">> publishing to branch $BRANCH on $remote"
	git clone -q "$HERE" "$PUBTMP/pub"
	(
		cd "$PUBTMP/pub"
		git checkout -q --orphan "$BRANCH"
		git rm -rqf . >/dev/null 2>&1 || true   # empty the branch (no source files, no history)
		cp "$DIST"/* .
		git add -A
		git -c user.name="mkrepo" -c user.email="mkrepo@localhost" \
			commit -q -m "Update $ARCH repository ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
		git push -qf "$remote" "$BRANCH"
	)
	echo ">> published. Users install from:"
	echo "   repository=https://raw.githubusercontent.com/${remote#*github.com[:/]}/$BRANCH" \
		| sed 's/\.git//'
}

if [ "$MODE" = publish ]; then
	# No build, no signing: skip the toolchain and key checks entirely, so this
	# runs on a machine that has neither xbps-src nor the private key.
	do_publish
	exit 0
fi

# --- sanity checks ---------------------------------------------------------
[ -x "$HERE/gen.sh" ] || { echo "error: gen.sh not found next to mkrepo.sh" >&2; exit 1; }
[ -x "$VOIDPKGS/xbps-src" ] || { echo "error: xbps-src not found under VOIDPKGS=$VOIDPKGS" >&2; exit 1; }
[ -f "$PRIVKEY" ] || { echo "error: signing key not found: $PRIVKEY" >&2; exit 1; }
command -v xbps-rindex >/dev/null || { echo "error: xbps-rindex not in PATH" >&2; exit 1; }

# --- signing passphrase ----------------------------------------------------
# If the key is passphrase-protected, read it once so the two signing steps
# below don't prompt twice. xbps-rindex picks it up from XBPS_PASSPHRASE.
if grep -q ENCRYPTED "$PRIVKEY" && [ -z "${XBPS_PASSPHRASE:-}" ]; then
	printf "Passphrase for signing key: " >&2
	stty -echo 2>/dev/null || true
	read XBPS_PASSPHRASE
	stty echo 2>/dev/null || true
	echo >&2
	export XBPS_PASSPHRASE
fi

# --- 1. pin the void-packages revision to build against --------------------
# Both halves of a release -- the generated template and the build environment
# (common/, build helpers, shlibs) -- come from one pinned revision, so whatever
# branch $VOIDPKGS happens to sit on never becomes part of what ships.
VOIDREF="${VOIDREF:-upstream/master}"
if [ "${FETCH:-1}" = 1 ] && [ "${VOIDREF#*/}" != "$VOIDREF" ]; then
	_remote="${VOIDREF%%/*}"
	if git -C "$VOIDPKGS" remote get-url "$_remote" >/dev/null 2>&1; then
		echo ">> fetching $_remote in $VOIDPKGS"
		git -C "$VOIDPKGS" fetch -q "$_remote" ||
			echo "warning: fetch failed; using $VOIDREF as it stands" >&2
	fi
fi
VOIDSHA=$(git -C "$VOIDPKGS" rev-parse --verify -q "$VOIDREF^{commit}") || {
	echo "error: cannot resolve VOIDREF=$VOIDREF in $VOIDPKGS" >&2; exit 1; }
echo ">> building against void-packages $VOIDREF ($(printf %.11s "$VOIDSHA"))"

# A detached worktree shares the object store, so this costs no clone and no
# network, and it leaves the branch and working tree in $VOIDPKGS untouched.
WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/${PKG}-build.XXXXXX")
rm -rf "$WORKTREE"   # git insists on creating the directory itself
git -C "$VOIDPKGS" worktree add -q --detach "$WORKTREE" "$VOIDSHA" || {
	echo "error: could not create a worktree at $WORKTREE" >&2; exit 1; }

# etc/conf is gitignored, so a fresh worktree does not have it; without it local
# settings (XBPS_ALLOW_RESTRICTED, XBPS_MAKEJOBS, ...) quietly revert to the
# defaults halfway through a release.
if [ -f "$VOIDPKGS/etc/conf" ]; then
	echo ">> carrying over etc/conf"
	cp "$VOIDPKGS/etc/conf" "$WORKTREE/etc/conf"
fi

# --- 2. generate the template from upstream, then stage it for the build ---
# srcpkg/$PKG is a generated artifact (see gen.sh): upstream's srcpkgs/linux-asahi
# plus our header, renames and patches. Generating here keeps the git copy equal
# to what actually gets built, and picks up upstream's template fixes.
if [ "${SKIP_GEN:-0}" = 1 ]; then
	echo ">> skipping generation (SKIP_GEN=1); building srcpkg/$PKG as committed"
	[ -f "$HERE/srcpkg/$PKG/template" ] || { echo "error: srcpkg/$PKG/template missing" >&2; exit 1; }
else
	echo ">> generating srcpkg/$PKG from ${GENFROM:-$VOIDREF}"
	"$HERE/gen.sh" --from "${GENFROM:-$VOIDSHA}"
fi

echo ">> staging srcpkg/$PKG into the worktree"
cp -a "$HERE/srcpkg/$PKG" "$WORKTREE/srcpkgs/"

# xbps-src resolves every subpackage through its own srcpkgs/ entry, which must
# be a symlink to the parent package's directory (that is how upstream ships
# linux-asahi-headers and -dbg). Without them the build dies at the packaging
# stage -- after the full kernel compile -- with "nonexistent file:
# srcpkgs/$PKG-dbg/template". Derive them from the template so a subpackage
# added upstream does not reintroduce that hours-late failure.
subpkgs=$(sed -n 's/^\([a-zA-Z0-9._-]*\)_package() *{.*/\1/p' "$WORKTREE/srcpkgs/$PKG/template")
for sub in $subpkgs; do
	[ "$sub" = "$PKG" ] && continue
	echo ">> linking srcpkgs/$sub -> $PKG"
	ln -sfn "$PKG" "$WORKTREE/srcpkgs/$sub"
done

# --- 3. build --------------------------------------------------------------
# Build in the worktree, but keep using the masterdir and hostdir of $VOIDPKGS:
# a private masterdir would mean a full bootstrap, and a private hostdir would
# throw away the ccache and re-download every distfile. xbps-src takes its own
# lock on the masterdir, so this serialises against a build running there.
#
# XBPS_ALT_REPOSITORY fixes where the binary packages land. Left alone, xbps-src
# derives that from the git branch, so the output path would depend on a
# checkout's state; it is also one of the few variables that survive the chroot
# boundary, which xbps-src crosses with "env -i" and a whitelist.
export XBPS_ALT_REPOSITORY="$PKG"
echo ">> building $PKG in $WORKTREE"
( cd "$WORKTREE" && ./xbps-src \
	-m "$VOIDPKGS/masterdir-$ARCH" -H "$VOIDPKGS/hostdir" \
	${REUSE_BINPKG:+-e} pkg "$PKG" )

# --- 4. collect artifacts (main + headers only; no -dbg) -------------------
# Subpackages that set repository= land one level deeper (here just -dbg, with
# repository=debug, which we do not distribute).

binroot="$VOIDPKGS/hostdir/binpkgs/$XBPS_ALT_REPOSITORY"
_version=$(sed -n 's/^version=//p' "$WORKTREE/srcpkgs/$PKG/template" | head -1)
_revision=$(sed -n 's/^revision=//p' "$WORKTREE/srcpkgs/$PKG/template" | head -1)
[ -n "$_version" ] && [ -n "$_revision" ] || {
	echo "error: could not read version/revision from the staged template" >&2; exit 1; }
PKGVER="${_version}_${_revision}"

echo ">> assembling repository in $DIST ($PKGVER)"
rm -rf "$DIST"; mkdir -p "$DIST"
for sub in "$PKG" $subpkgs; do   # $subpkgs holds the subpackages only
	case "$sub" in
	*-dbg) continue ;;   # built into $binroot/debug/, intentionally not shipped
	esac
	f="$binroot/${sub}-${PKGVER}.${ARCH}.xbps"
	[ -f "$f" ] || { echo "error: expected artifact missing: $f" >&2; exit 1; }
	echo ">> collecting ${sub}-${PKGVER}.${ARCH}.xbps"
	cp "$f" "$DIST"/
done

# --- 5. index + sign -------------------------------------------------------
echo ">> indexing"
xbps-rindex -a "$DIST"/*.xbps
echo ">> signing repository metadata"
xbps-rindex --sign --signedby "$SIGNEDBY" --privkey "$PRIVKEY" "$DIST"
echo ">> signing packages"
xbps-rindex --sign-pkg --privkey "$PRIVKEY" "$DIST"/*.xbps

echo
echo "Repository ready: $DIST"
ls -1 "$DIST"

# --- 6. publish to the orphan branch ---------------------------------------
if [ "$MODE" = all ]; then
	do_publish
else
	cat <<EOF

Not published. Try this build first:

  sudo xbps-install --repository=$DIST $PKG

then publish exactly these packages, without rebuilding or re-signing:

  ${0##*/} publish

Users install from:
  repository=https://raw.githubusercontent.com/omemoji/void-asahi-fairydust/$BRANCH
EOF
fi
