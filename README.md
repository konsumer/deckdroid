# deckdroid

Waydroid on the Steam Deck, installed wherever you want, started only when you
need it.

- **No compiling.** The Waydroid stack is built by GitHub Actions against the
  exact SteamOS package set and shipped as a relocatable tarball.
- **Install anywhere.** Point it at an SD card or a second drive; nothing is
  written to the read-only rootfs.
- **Runs on demand.** Start and stop it so it is not eating memory while you
  play something else.
- **One Steam entry per Android app**, reusing the app's own icon.

## Install

```bash
curl -sSfL https://raw.githubusercontent.com/konsumer/deckdroid/main/install.sh | bash
```

Somewhere other than `/home`:

```bash
curl -sSfL .../install.sh | bash -s -- --root /run/media/deck/SD/Android --size 64G
```

## Use

```bash
deckdroid start | stop | status       # manage the service
deckdroid ui                          # the full Android UI
deckdroid app install some.apk        # installs, then refreshes icons
deckdroid shortcuts sync              # one Steam entry per app; restart Steam after
deckdroid shortcuts sync --all        # include LineageOS's stock apps too
deckdroid shortcuts remove            # take ours back out
deckdroid launch org.fdroid.fdroid
deckdroid refresh                     # regenerate icons and desktop entries
deckdroid doctor                      # what is wrong, if anything
```

`shortcuts sync` only picks up apps you installed: waydroid marks LineageOS's
stock apps (Clock, Contacts, ...) hidden, and a Steam library is nicer without
them. Use `--all` if you want them anyway. Your own hand-made non-Steam
shortcuts are never touched, and `shortcuts.vdf` is backed up before the first
write.

Each generated Steam shortcut runs `deckdroid launch <package>`: it starts the
service if it is down, runs the app in its own compositor, and shuts everything
down when you close it.

## Requirements

SteamOS **3.8.16** or newer on a kernel that has binder built in. Check with:

```bash
grep binder /proc/filesystems     # want: nodev binder
```

Valve enables binder on the 6.15 and 6.16 kernels but *not* on 6.11, 6.18 or
7.2, so this is worth checking rather than assuming. See
[docs/kernels.md](docs/kernels.md).

## How it fits together

| Piece | What it does |
| ----- | ------------ |
| `build/Dockerfile` | Arch image repointed at Valve's `*-3.8.1x` repos, so builds link against the Deck's actual glibc 2.41 / Python 3.13 |
| `build/build-bundle.sh` | Resolves binary deps with pacman, prunes everything SteamOS already ships, builds the gbinder/waydroid stack, packs a tarball |
| `build/verify-bundle.sh` | Untars to a random path and asserts every needed soname resolves against the bundle or a real Deck's library inventory |
| `src/deckdroid` | The CLI |
| `src/deckdroid-root` | The only privileged code: loop-mount, container, `pid_max` |
| `src/deckdroid-shortcuts` | Merges Android apps into Steam's `shortcuts.vdf` |

## Verified on

SteamOS 3.8.16, kernel 6.16.12-valve24.5, Steam Deck. Full path exercised:
install from the published release, Android boot, APK install, Steam shortcut
generation with the app's own icon, launch, and automatic shutdown when the app
closes.

Two design notes worth knowing:

**Why a disk image.** Waydroid hardcodes `/var/lib/waydroid`, and on the Deck
`/var` is a 230 MB A/B partition that updates replace. So the Android data lives
in an ext4 image in *your* directory, loop-mounted onto that path at start. It
also means the SD card works no matter how it was formatted.

**Why nothing lands in `/usr`.** SteamOS replaces the whole rootfs on update, so
anything installed there is gone next patch. The bundle runs from your directory
via `PATH`/`LD_LIBRARY_PATH`/`PYTHONPATH`. The only system files are a sudoers
rule and a D-Bus policy, both in `/etc`, both re-appliable with
`deckdroid doctor`.

**Why `lxc.rootfs.mount` is patched.** LXC compiles in `/usr/lib/lxc/rootfs` as
the mount point for a container rootfs. That path cannot be created on a
read-only rootfs and is not relocatable, so `lxc-start` fails with "Failed to
prepare rootfs storage". The build points it at a tmpfs path instead, and the
root helper repairs already-generated configs in place.
