# void-asahi-fairydust

An unofficial [Void Linux](https://voidlinux.org) binary package repository for
**`linux-asahi-fairydust`** — the Apple Silicon (Asahi) kernel built from the
upstream [`fairydust`](https://github.com/AsahiLinux/linux/tree/fairydust)
branch, which adds **USB-C DisplayPort Alt Mode video output**.

This is especially useful on Macs whose only external video path is USB-C
(e.g. the **M1/M2 MacBook Air**, which has no HDMI port).

> [!WARNING]
> **Experimental. Use at your own risk.** The `fairydust` branch is provided by
> upstream Asahi *strictly as-is*, is aimed at developers, and is **not
> considered ready for general use** — upstream offers no support for it.
> This repository just makes prebuilt packages available; it inherits all of
> those caveats. Do not use this on a machine you cannot afford to recover.

## Known limitations (from upstream)

USB-C DP alt mode here relies on four reverse-engineered hardware blocks
(DCP, DPXBAR, ATCPHY, ACE). Current constraints:

- **One port only.** A single specific USB-C port is "blessed" for DisplayPort —
  use the **front port on the left side**. Multiple USB-C displays are not
  possible.
- **Hotplug is flaky.** Both cold- and hot-plug have quirks.
- **Color/timing issues.** Some displays show incorrect/oversaturated colors or
  missing modes (DCP limitations).

## Requirements

- A Void Linux **aarch64** install on Apple Silicon (an existing working Asahi
  Void system — see the [Asahi](https://asahilinux.org) / Void aarch64 docs).

## Installation

1. **Add the repository.** Create `/etc/xbps.d/10-void-asahi-fairydust.conf`:

   ```
   repository=https://raw.githubusercontent.com/omemoji/void-asahi-fairydust/repository-aarch64
   ```

2. **Sync and install.** On first sync, xbps will show the repository's signing
   key fingerprint and ask you to import it — verify it (see below) and accept:

   ```sh
   sudo xbps-install -S
   sudo xbps-install linux-asahi-fairydust
   ```

   The kernel hooks will regenerate the initramfs and update the bootloader for
   the `...-asahi-fairydust_1` kernel automatically. Reboot and select it.

3. **(Optional) headers**, for building out-of-tree modules (e.g. DKMS):

   ```sh
   sudo xbps-install linux-asahi-fairydust-headers
   ```

### Verifying the signing key

The public key is committed here as [`pubkey.pem`](./pubkey.pem). Its SHA-256
fingerprint is:

```
0687d83c1641bdcbe4dfd866fcfc5e31d3b02447a48bcf06be37e4988fc5702f
```

Reproduce it yourself from `pubkey.pem`:

```sh
openssl rsa -pubin -in pubkey.pem -outform DER | openssl dgst -sha256
```

## Updating

The `fairydust` branch is a rolling snapshot pinned to a specific commit; the
package `version` encodes the base kernel plus the commit date
(e.g. `7.1.5+20260727`). When a new snapshot is published here, a plain
`sudo xbps-install -Su` will pick it up (`preserve=yes` keeps older kernels
installed so you can fall back).

## Reverting to the official kernel

```sh
sudo xbps-install linux-asahi          # ensure the official kernel is present
sudo xbps-remove linux-asahi-fairydust # remove this one
```

Reboot into `linux-asahi`. Because kernels are preserved, you can always keep
both installed and just pick the other entry at boot if something misbehaves.

## Building from source

The package template is committed under [`srcpkg/`](./srcpkg/). To build it
yourself, drop it into a [void-packages](https://github.com/void-linux/void-packages)
checkout and use `xbps-src`:

```sh
cp -r srcpkg/linux-asahi-fairydust <void-packages>/srcpkgs/
cd <void-packages>
# xbps-src needs a srcpkgs/ entry per subpackage, symlinked to the parent --
# without these the build fails at the packaging stage, after the full compile
ln -sfn linux-asahi-fairydust srcpkgs/linux-asahi-fairydust-headers
ln -sfn linux-asahi-fairydust srcpkgs/linux-asahi-fairydust-dbg
./xbps-src pkg linux-asahi-fairydust
```

Maintainers can rebuild + sign + assemble this repository with
[`mkrepo.sh`](./mkrepo.sh); see [Maintaining the repository](#maintaining-the-repository).

### How the template tracks upstream

`srcpkg/linux-asahi-fairydust/` is a **generated** artifact, not a hand-edited
fork. It is void-packages' own `srcpkgs/linux-asahi` with these layered on by
[`gen.sh`](./gen.sh):

| input                                             | what it contributes                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------------------ |
| [`srcpkg/header.in`](./srcpkg/header.in)          | the metadata head: `pkgname`, `version`, `_commit`, `distfiles`, `checksum`    |
| upstream's template, from `python_version=3` down | everything else, with `asahi` → `asahi-fairydust` renames applied mechanically |
| `srcpkg/patches/*.patch`                          | our genuine build fixes — **currently none**, see below                        |
| [`srcpkg/config-extra`](./srcpkg/config-extra)    | kernel config answers appended to `files/arm64-dotconfig`                      |

`files/mv-debug` is copied from upstream verbatim, and `files/arm64-dotconfig`
is too apart from the appended fragment. So upstream's changes — new header file
lists in `do_install`, `hostmakedepends` bumps, config changes — are inherited
automatically, and anything that collides with our patches fails the generation
loudly instead of rotting silently. [`srcpkg/UPSTREAM`](./srcpkg/UPSTREAM)
records which void-packages revision the committed output was generated from.

The one patch this repository used to carry pointed the kernel's Rust
`--extern` flags at its in-tree rlibs: Void's `rust-std` ships
`proc_macro2`/`quote`/`syn` in the compiler sysroot, which upstream Rust does
not, so `rustc` sees two candidates for each and fails with `E0464`. Upstream
void-packages now does the same substitution in `pre_configure()`, so the patch
was dropped. Upstream comments it "can be dropped once aarch64 is built
natively" — but for us the collision comes from Void's `rust-std`, not from
cross-building, so `gen.sh` asserts that line still exists and fails generation
if it disappears rather than letting an hours-long build hit `E0464`.

#### Answering new kernel config symbols

`arm64-dotconfig` is upstream's, answered for upstream's base kernel. The
fairydust snapshot usually runs ahead of it, so symbols that only exist in the
newer tree are unanswered and `make oldconfig` stops for input part-way through
a build. Record the answer in [`srcpkg/config-extra`](./srcpkg/config-extra) —
plain `.config` syntax, `CONFIG_FOO=m` or `# CONFIG_FOO is not set` — and
`gen.sh` appends it to the generated dotconfig, so the build runs unattended:

```
CONFIG_TYPEC_SN201202X=m
```

This is the `patches/` idea applied to the config: the entries are ours, and
when upstream's dotconfig starts answering a symbol itself, generation fails
with the symbol name so the now-redundant line can be dropped. `--check`
compares the dotconfig against upstream *plus* the fragment, so the drift report
stays meaningful.

```sh
./gen.sh                      # regenerate from the void-packages working tree
./gen.sh --check              # report drift since the last sync; exits 1 on drift
./gen.sh --from <rev>         # generate against a specific void-packages revision
./gen.sh --bump <sha|branch>  # repin the fairydust snapshot (rewrites header.in)
```

`mkrepo.sh` regenerates before every build, so the committed `srcpkg/` always
equals what was actually built and published. Pass `SKIP_GEN=1` to build the
committed template as-is, or `GENFROM=<rev>` to reproduce an older sync.

### Maintaining the repository

[`mkrepo.sh`](./mkrepo.sh) keeps building and publishing separate, so a build can
be test-installed on real hardware before anyone else sees it:

```sh
./mkrepo.sh          # generate, build, index, sign -> dist/aarch64/ (default)
./mkrepo.sh publish  # force-push dist/aarch64/ to the repository-aarch64 branch
./mkrepo.sh all      # both, in one go
```

`dist/aarch64/` is a complete signed xbps repository, so the build can be
installed straight from disk before it is published — reboot into it, confirm
the display actually comes up, and only then publish:

```sh
sudo xbps-install --repository=$PWD/dist/aarch64 linux-asahi-fairydust
```

`publish` neither rebuilds nor re-signs: it ships exactly the bytes that were
tested, and refuses to run if `dist/aarch64/` is missing its index or any
package signature. It needs no signing key and no void-packages checkout, so it
can run from a different machine than the build. The branch is recreated as a
single orphan commit each time, in a throwaway clone, so the branch you are
working on is untouched and the history does not accumulate old kernels.

The [`track-upstream`](./.github/workflows/track-upstream.yml) workflow runs
`gen.sh --check` weekly and also compares `_commit` against the head of the
`fairydust` branch, filing a single self-updating issue when either moves. It
never builds — that needs aarch64 hardware — it only makes the drift visible.

## Credits & license

USB-C display support is the work of the Asahi Linux project (Sven Peter,
Janne Grunau, Hector "marcan" Martin, and others). The kernel is licensed
`GPL-2.0-only`. This repository only packages and redistributes their work; see
the [Asahi Linux progress report](https://asahilinux.org/2026/02/progress-report-6-19/)
for the authoritative status of the `fairydust` branch.

The packaging material here — `gen.sh`, `mkrepo.sh`, the workflows, this README
and the template sources under `srcpkg/` — is [BSD-2-Clause](./LICENSE), matching
void-packages, from which `srcpkg/linux-asahi-fairydust/` is generated. That
license covers only those files; the kernel and the published `.xbps` packages
remain `GPL-2.0-only`, and their corresponding source is the commit pinned as
`_commit` in [`srcpkg/header.in`](./srcpkg/header.in).
