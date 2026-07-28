#!/bin/sh
# Build linux-asahi-fairydust in a void-packages checkout, sign an xbps binary
# repository under ./dist/<arch>/, and (optionally) publish it to the orphan
# branch "repository-<arch>" which is served to users via raw.githubusercontent.
#
# The -dbg package is intentionally NOT distributed (the official Void repos
# don't ship debug packages in the main repository either).
#
# Usage:
#   ./mkrepo.sh              # build + sign into ./dist/aarch64 only
#   PUBLISH=1 ./mkrepo.sh    # also force-push it to the repository-aarch64 branch
#
# Overridable via environment:
#   VOIDPKGS   path to the void-packages checkout (default: ~/github/omemoji/void-packages)
#   KEYDIR     dir holding privkey.pem            (default: ~/.config/void-asahi-fairydust)
#   SIGNEDBY   signature identity string
#   XBPS_PASSPHRASE  passphrase for the (encrypted) signing key; prompted if unset
#   GENFROM    void-packages revision to generate the template from (default: its
#              working tree); passed to gen.sh --from
#   SKIP_GEN=1 build srcpkg/ as committed, without regenerating from upstream
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

# --- 1. generate the template from upstream, then stage it for the build ---
# srcpkg/$PKG is a generated artifact (see gen.sh): upstream's srcpkgs/linux-asahi
# plus our header, renames and patches. Generating here keeps the git copy equal
# to what actually gets built, and picks up upstream's template fixes.
if [ "${SKIP_GEN:-0}" = 1 ]; then
	echo ">> skipping generation (SKIP_GEN=1); building srcpkg/$PKG as committed"
	[ -f "$HERE/srcpkg/$PKG/template" ] || { echo "error: srcpkg/$PKG/template missing" >&2; exit 1; }
else
	echo ">> generating srcpkg/$PKG from $VOIDPKGS"
	if [ -n "${GENFROM:-}" ]; then
		"$HERE/gen.sh" --from "$GENFROM"
	else
		"$HERE/gen.sh"
	fi
fi

echo ">> staging srcpkg/$PKG into $VOIDPKGS/srcpkgs"
rm -rf "$VOIDPKGS/srcpkgs/$PKG"
cp -a "$HERE/srcpkg/$PKG" "$VOIDPKGS/srcpkgs/"

# xbps-src resolves every subpackage through its own srcpkgs/ entry, which must
# be a symlink to the parent package's directory (that is how upstream ships
# linux-asahi-headers and -dbg). Without them the build dies at the packaging
# stage -- after the full kernel compile -- with "nonexistent file:
# srcpkgs/$PKG-dbg/template". Derive them from the template so a subpackage
# added upstream does not reintroduce that hours-late failure.
subpkgs=$(sed -n 's/^\([a-zA-Z0-9._-]*\)_package() *{.*/\1/p' "$VOIDPKGS/srcpkgs/$PKG/template")
for sub in $subpkgs; do
	[ "$sub" = "$PKG" ] && continue
	link="$VOIDPKGS/srcpkgs/$sub"
	if [ -e "$link" ] && [ ! -L "$link" ]; then
		echo "error: $link exists and is not a symlink; refusing to touch it" >&2
		exit 1
	fi
	echo ">> linking srcpkgs/$sub -> $PKG"
	ln -sfn "$PKG" "$link"
done

# --- 2. build --------------------------------------------------------------
echo ">> building $PKG in $VOIDPKGS"
( cd "$VOIDPKGS" && ./xbps-src pkg "$PKG" )

# --- 3. collect artifacts (main + headers only; no -dbg) -------------------
# xbps-src drops binary packages in hostdir/binpkgs itself; only subpackages
# that set repository= land in a subdirectory (here just -dbg, repository=debug,
# which we do not distribute).
binroot="$VOIDPKGS/hostdir/binpkgs"
_version=$(sed -n 's/^version=//p' "$VOIDPKGS/srcpkgs/$PKG/template" | head -1)
_revision=$(sed -n 's/^revision=//p' "$VOIDPKGS/srcpkgs/$PKG/template" | head -1)
[ -n "$_version" ] && [ -n "$_revision" ] || {
	echo "error: could not read version/revision from srcpkgs/$PKG/template" >&2; exit 1; }
PKGVER="${_version}_${_revision}"

echo ">> assembling repository in $DIST ($PKGVER)"
rm -rf "$DIST"; mkdir -p "$DIST"
for sub in "$PKG" $subpkgs; do   # $subpkgs holds the subpackages only
	case "$sub" in
	*-dbg) continue ;;   # built into binpkgs/debug/, intentionally not shipped
	esac
	f="$binroot/${sub}-${PKGVER}.${ARCH}.xbps"
	[ -f "$f" ] || { echo "error: expected artifact missing: $f" >&2; exit 1; }
	echo ">> collecting ${sub}-${PKGVER}.${ARCH}.xbps"
	cp "$f" "$DIST"/
done

# --- 4. index + sign -------------------------------------------------------
echo ">> indexing"
xbps-rindex -a "$DIST"/*.xbps
echo ">> signing repository metadata"
xbps-rindex --sign --signedby "$SIGNEDBY" --privkey "$PRIVKEY" "$DIST"
echo ">> signing packages"
xbps-rindex --sign-pkg --privkey "$PRIVKEY" "$DIST"/*.xbps

echo
echo "Repository ready: $DIST"
ls -1 "$DIST"

# --- 5. publish to the orphan branch ---------------------------------------
# Done in a throwaway clone so the working tree/branch you are on is untouched.
# The branch is recreated from scratch each time (single commit, no history
# bloat from large binaries).
if [ "${PUBLISH:-0}" = 1 ]; then
	remote=$(git -C "$HERE" remote get-url origin)
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	echo ">> publishing to branch $BRANCH on $remote"
	git clone -q "$HERE" "$tmp/pub"
	cd "$tmp/pub"
	git checkout -q --orphan "$BRANCH"
	git rm -rqf . >/dev/null 2>&1 || true   # empty the branch (no source files, no history)
	cp "$DIST"/* .
	git add -A
	git -c user.name="mkrepo" -c user.email="mkrepo@localhost" \
		commit -q -m "Update $ARCH repository ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
	git push -qf "$remote" "$BRANCH"
	echo ">> published. Users install from:"
	echo "   repository=https://raw.githubusercontent.com/${remote#*github.com[:/]}/$BRANCH" \
		| sed 's/\.git//'
else
	cat <<EOF

Not published (set PUBLISH=1 to push). To publish manually, force-push the
contents of $DIST to the '$BRANCH' branch (orphan, single commit).

Users install from:
  repository=https://raw.githubusercontent.com/omemoji/void-asahi-fairydust/$BRANCH
EOF
fi
