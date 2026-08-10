#!/bin/sh
# Generate srcpkg/linux-asahi-fairydust from void-packages' srcpkgs/linux-asahi.
#
# The fairydust package is upstream's linux-asahi template with a different
# source pin and a different kernel name. Rather than vendoring a full copy that
# silently rots, the template is *generated*:
#
#   srcpkg/header.in            -> the metadata head (pkgname/version/_commit/...)
#   upstream template, line 11+ -> everything else, with the asahi -> asahi-fairydust
#                                  renames applied mechanically
#   srcpkg/patches/*.patch      -> our genuine modifications (currently none:
#                                  upstream carries the one fix we used to add)
#   files/                      -> copied verbatim from upstream
#
# Anything upstream changes below the head (headers file lists, hostmakedepends,
# do_install, ...) is therefore picked up for free; anything that collides with
# our patches, or removes something we depend on, makes this script fail loudly,
# which is the point.
#
# Usage:
#   ./gen.sh                 regenerate srcpkg/linux-asahi-fairydust
#   ./gen.sh --check         report upstream drift since the last sync; no writes
#   ./gen.sh --bump <ref>    repin the snapshot to a fairydust commit (sha or branch)
#   ./gen.sh --from <rev>    generate against a void-packages revision instead of
#                            its working tree (reproduces an older sync)
#
# --from also applies to --check, so `./gen.sh --from HEAD --check` answers
# "what did upstream change since we last synced" without touching the checkout.
#
# Overridable via environment:
#   VOIDPKGS   path to the void-packages checkout (default: ~/github/omemoji/void-packages)
set -eu

VOIDPKGS="${VOIDPKGS:-$HOME/github/omemoji/void-packages}"
UPSTREAM_PKG=linux-asahi
PKG=linux-asahi-fairydust
GITHUB_REPO=AsahiLinux/linux

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
SRCPKG="$HERE/srcpkg"
HEADER="$SRCPKG/header.in"
PATCHDIR="$SRCPKG/patches"
STAMP="$SRCPKG/UPSTREAM"
OUT="$SRCPKG/$PKG"

FROM=""      # void-packages revision to read upstream from ("" = working tree)
USRC=""      # directory holding the upstream template + files/ once resolved
TMPDIR_=""

die() { echo "error: $*" >&2; exit 1; }
# must not change the exit status: a trap whose last command fails would
# override it, and --check's status is what CI reads.
cleanup() { if [ -n "$TMPDIR_" ]; then rm -rf "$TMPDIR_"; fi; }
trap cleanup EXIT

# Materialize srcpkgs/linux-asahi -- from the working tree, or extracted from a
# git revision when --from was given -- and set $USRC / $UT to it.
resolve_upstream() {
	if [ -z "$FROM" ]; then
		USRC="$VOIDPKGS/srcpkgs/$UPSTREAM_PKG"
	else
		git -C "$VOIDPKGS" rev-parse --verify -q "$FROM^{commit}" >/dev/null ||
			die "not a void-packages revision: $FROM"
		TMPDIR_=$(mktemp -d)
		USRC="$TMPDIR_/$UPSTREAM_PKG"
		mkdir -p "$USRC"
		git -C "$VOIDPKGS" archive "$FROM" "srcpkgs/$UPSTREAM_PKG" \
			| tar -x -C "$TMPDIR_" --strip-components=1 -f - ||
			die "cannot extract srcpkgs/$UPSTREAM_PKG at $FROM"
	fi
	UT="$USRC/template"
}

upstream_rev() {
	if [ -n "$FROM" ]; then
		git -C "$VOIDPKGS" rev-parse "$FROM"
	else
		git -C "$VOIDPKGS" rev-parse HEAD 2>/dev/null || echo unknown
	fi
}

# The head of the upstream template (metadata) is replaced wholesale by
# header.in; the rest is reused. HEAD_LINES is where that cut happens and must
# land exactly on the blank line preceding "python_version=3" -- verified below
# so an upstream reshuffle fails here instead of producing a broken template.
HEAD_LINES=10

check_layout() {
	[ -f "$UT" ] || die "upstream template not found: $UT"
	[ -n "$(sed -n "$((HEAD_LINES + 1))p" "$UT" | tr -d '[:space:]')" ] &&
		die "upstream template layout changed: line $((HEAD_LINES + 1)) is not blank"
	[ "$(sed -n "$((HEAD_LINES + 2))p" "$UT")" = "python_version=3" ] ||
		die "upstream template layout changed: line $((HEAD_LINES + 2)) is not 'python_version=3'"
	# the head we drop must not have grown anything but metadata
	if sed -n "1,${HEAD_LINES}p" "$UT" | grep -qv \
		-e '^#' -e '^pkgname=' -e '^version=' -e '^revision=' -e '^short_desc=' \
		-e '^maintainer=' -e '^license=' -e '^homepage=' -e '^distfiles=' -e '^checksum='
	then
		echo "warning: unexpected assignment in the upstream metadata head;" >&2
		echo "         review it -- header.in may need the same key:" >&2
		sed -n "1,${HEAD_LINES}p" "$UT" | grep -nv \
			-e '^#' -e '^pkgname=' -e '^version=' -e '^revision=' -e '^short_desc=' \
			-e '^maintainer=' -e '^license=' -e '^homepage=' -e '^distfiles=' -e '^checksum=' >&2
	fi
}

upstream_version() { sed -n 's/^version=//p' "$UT"; }
upstream_sum() { sha256sum "$UT" | cut -d' ' -f1; }
our_version() { sed -n 's/^version=//p' "$HEADER"; }

stamp_get() { [ -f "$STAMP" ] && sed -n "s/^$1: //p" "$STAMP" || true; }

# --- generate --------------------------------------------------------------
generate() {
	resolve_upstream
	check_layout

	rm -rf "$OUT"
	mkdir -p "$OUT"
	cp -a "$USRC/files" "$OUT/files"
	# upstream's update(1) file follows the asahi-* tags; we pin a commit on an
	# untagged branch, so ours is always the disabled one.
	printf '%s\n' \
		'disabled="tracks a specific commit of the untagged fairydust branch"' \
		> "$OUT/update"

	{
		cat "$HEADER"
		tail -n +"$((HEAD_LINES + 1))" "$UT"
	} | sed \
		-e 's/-asahi_${revision}/-asahi-fairydust_${revision}/g' \
		-e "s/^${UPSTREAM_PKG}-\(headers\|dbg\)_package()/${PKG}-\1_package()/" \
		> "$OUT/template"

	# the renames above are load-bearing: verify none of them silently missed
	grep -q '^_kernver=${version}-asahi-fairydust_${revision}$' "$OUT/template" ||
		die "_kernver rename did not apply (upstream changed the line?)"
	grep -q -- '-asahi-fairydust_${revision}\\"|" .config' "$OUT/template" ||
		die "CONFIG_LOCALVERSION rename did not apply (upstream changed the line?)"
	for sub in headers dbg; do
		grep -q "^${PKG}-${sub}_package()" "$OUT/template" ||
			die "${sub} subpackage rename did not apply"
	done
	! grep -q "${UPSTREAM_PKG}-\(headers\|dbg\)" "$OUT/template" ||
		die "leftover '${UPSTREAM_PKG}-headers/-dbg' reference in the generated template"

	# Void's rust-std ships proc_macro2/quote/syn in the compiler sysroot, which
	# upstream Rust does not, so the kernel's in-tree copies collide with them
	# and rustc fails with E0464. We used to patch the fix in; upstream now does
	# it in pre_configure(), commented "can be dropped once aarch64 is built
	# natively" -- but the collision is a property of Void's rust-std, not of
	# cross-building, so it would come back for us. Fail here rather than hours
	# into a build if that line disappears; the patch is in git history
	# (srcpkg/patches/0001-rust-extern-disambiguate.patch) to restore.
	grep -q 'libproc_macro2\.rlib' "$OUT/template" ||
		die "upstream dropped the rust --extern disambiguation from pre_configure().
E0464 will come back on Void (its rust-std ships proc_macro2/quote/syn).
Restore srcpkg/patches/0001-rust-extern-disambiguate.patch from git history."

	for p in "$PATCHDIR"/*.patch; do
		[ -e "$p" ] || continue
		echo ">> applying $(basename "$p")"
		patch -s -p1 -d "$OUT" --no-backup-if-mismatch < "$p" || die \
"$(basename "$p") does not apply.

Upstream touched the code this patch depends on. Either it fixed the same
thing (drop the patch) or the surrounding context moved (refresh it against
$UT). Regenerate once resolved."
	done

	# no timestamp here on purpose: regenerating without an upstream change must
	# leave the tree clean, and git already records when the sync happened.
	printf 'void-packages: %s\nupstream-version: %s\ntemplate-sha256: %s\n' \
		"$(upstream_rev)" \
		"$(upstream_version)" \
		"$(upstream_sum)" \
		> "$STAMP"

	base_warning
	echo "generated: $OUT (from $UPSTREAM_PKG $(upstream_version))"
}

# The fairydust branch and upstream linux-asahi track the same base kernel most
# of the time. When they diverge, files/arm64-dotconfig (taken from upstream)
# no longer matches the tree being built and `make oldconfig` will stop for
# input mid-build, so say so before an hours-long build discovers it.
base_warning() {
	ub=$(upstream_version); ub=${ub%%+*}
	ob=$(our_version); ob=${ob%%+*}
	[ "$ub" = "$ob" ] && return 0
	cat >&2 <<EOF
warning: base kernel mismatch -- upstream linux-asahi is $ub, this package
         pins $ob. files/arm64-dotconfig comes from upstream, so oldconfig may
         prompt during the build. Repin with --bump, or expect to answer it.
EOF
}

# --- check -----------------------------------------------------------------
check() {
	resolve_upstream
	check_layout
	rc=0

	was=$(stamp_get template-sha256)
	now=$(upstream_sum)
	if [ "$was" = "$now" ]; then
		echo "up to date with $UPSTREAM_PKG $(upstream_version) (template unchanged)"
	else
		echo "UPSTREAM DRIFT: srcpkgs/$UPSTREAM_PKG/template changed since the last sync"
		echo "  was $was"
		echo "  now $now  (version $(upstream_version))"
		rc=1
	fi

	# files/ is used verbatim, so a change there matters just as much --
	# including one appearing or disappearing
	for f in "$USRC/files/"*; do
		b=$(basename "$f")
		if [ ! -e "$OUT/files/$b" ]; then
			echo "UPSTREAM DRIFT: files/$b is new upstream"
			rc=1
		elif ! cmp -s "$f" "$OUT/files/$b"; then
			echo "UPSTREAM DRIFT: files/$b differs from the generated copy"
			rc=1
		fi
	done
	for f in "$OUT/files/"*; do
		b=$(basename "$f")
		if [ ! -e "$USRC/files/$b" ]; then
			echo "UPSTREAM DRIFT: files/$b was removed upstream"
			rc=1
		fi
	done

	base_warning
	return $rc
}

# --- bump ------------------------------------------------------------------
# Repins header.in to a fairydust commit: rewrites _commit, the date suffix in
# version, and the contents checksum (which has to be computed the way xbps-src
# does it -- sha256 over `tar -xO`, not over the gzip stream).
bump() {
	ref="${1:?usage: gen.sh --bump <sha|branch>}"
	command -v curl >/dev/null || die "curl is required for --bump"

	echo ">> resolving $GITHUB_REPO@$ref"
	meta=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/$GITHUB_REPO/commits/$ref") ||
		die "cannot reach the GitHub API"
	# committer date, not author date: it is what the version suffix means, and
	# rebased branches like fairydust have author dates far in the past.
	if command -v python3 >/dev/null; then
		set -- $(printf '%s' "$meta" | python3 -c \
			'import json,sys; c=json.load(sys.stdin); print(c["sha"], c["commit"]["committer"]["date"][:10].replace("-",""))')
		sha="${1:-}"; date="${2:-}"
	else
		sha=$(printf '%s' "$meta" | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
		date=$(printf '%s' "$meta" | tr '{,' '\n\n' | grep -A8 '"committer"' \
			| sed -n 's/.*"date": *"\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\).*/\1\2\3/p' | head -1)
	fi
	[ -n "$sha" ] && [ -n "$date" ] || die "could not parse sha/committer date from the API response"

	cur=$(sed -n 's/^_commit=//p' "$HEADER")
	if [ "$sha" = "$cur" ]; then
		echo "already pinned to $sha ($(our_version)); nothing to do"
		return 0
	fi

	oldbase=$(our_version); oldbase=${oldbase%%+*}
	echo ">> $cur -> $sha (committed $date)"

	# The version prefix is the base kernel release, which lives in the tree's
	# top-level Makefile -- read it rather than assuming the snapshot stayed on
	# the same base.
	mk=$(curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$sha/Makefile") ||
		die "cannot read the Makefile of $sha"
	base=$(printf '%s\n' "$mk" | awk -F'= *' '
		/^VERSION *=/    { v=$2 }
		/^PATCHLEVEL *=/ { p=$2 }
		/^SUBLEVEL *=/   { s=$2 }
		END { gsub(/ /,"",v); gsub(/ /,"",p); gsub(/ /,"",s);
		      if (v == "" || p == "") exit 1; print v "." p "." (s == "" ? "0" : s) }')
	[ -n "$base" ] || die "could not read VERSION/PATCHLEVEL/SUBLEVEL from the Makefile of $sha"
	if [ "$base" != "$oldbase" ]; then
		echo ">> base kernel moved: $oldbase -> $base"
	fi

	url="https://github.com/$GITHUB_REPO/archive/$sha.tar.gz"
	echo ">> computing contents checksum (downloads the tarball, this takes a while)"
	sum=$(curl -fsSL "$url" | tar -xOzf - | sha256sum | cut -d' ' -f1) ||
		die "failed to download or hash $url"

	tmp=$(mktemp)
	sed -e "s/^_commit=.*/_commit=$sha/" \
	    -e "s/^version=.*/version=$base+$date/" \
	    -e "s/^checksum=.*/checksum=@$sum/" \
	    -e "s/^revision=.*/revision=1/" \
	    "$HEADER" > "$tmp"
	mv "$tmp" "$HEADER"
	echo ">> header.in repinned to $base+$date"
	generate
}

action=generate
bumpref=""
while [ $# -gt 0 ]; do
	case "$1" in
		--generate) action=generate ;;
		--check) action=check ;;
		--bump) action=bump; shift; bumpref="${1:-}"
			[ -n "$bumpref" ] || die "--bump needs a commit sha or branch name" ;;
		--from) shift; FROM="${1:-}"
			[ -n "$FROM" ] || die "--from needs a void-packages revision" ;;
		-h|--help) sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

case "$action" in
	generate) generate ;;
	check) check ;;
	bump) bump "$bumpref" ;;
esac
