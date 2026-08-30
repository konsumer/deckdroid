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

## How a Game Mode launch works

Every step below is ordered the way it is because the alternative fails, and
most of them fail *silently*. This is the part worth reading before changing
anything.

1. **Start the container**, loop-mounting the data image over `/var/lib/waydroid`.
2. **Run cage on the wlroots X11 backend** (`WLR_BACKENDS=x11`) against the
   display Steam hands the shortcut. In Game Mode gamescope decides what to
   show through Xwayland (`steamcompmgr` on `:1`) and never displays a bare
   Wayland client, so cage on its *Wayland* backend draws into nothing and
   Steam spins forever. On the X11 backend it makes a plain X window that
   steamcompmgr focuses like any game.
3. **Size that window to the screen before starting the session.** cage's X11
   backend opens a fixed 1024x768 window, and Android reads its resolution from
   the compositor exactly once, at session start -- resize afterwards and
   Android stays 1024x768 and letterboxed. The parent does this and the child
   waits on a handshake file.
4. **Start the waydroid session inside the compositor.** Android's surfaces go
   to whatever display the session was started on; start it outside and the
   compositor supervises a process that draws nothing.
5. **Wait for `sys.boot_completed`.** `waydroid app list` answers long before
   Android is up, and an app started too early loses focus to the home screen.
6. **Show the display before launching the app.** Android will not resume an
   activity into a display that is not being presented -- launching first just
   fails, every retry.
7. **Start the app with `am start` on the resolved component.** `waydroid app
   launch` sets `waydroid.active_apps` to the package, which hides windows
   belonging to any *other* package -- including the first-run permission
   dialog (`com.android.permissioncontroller`). `monkey` exits 0 and does
   nothing at all.

`multi_windows` must be off. It is a *persisted* Android property in the data
image, so it outranks `waydroid_base.prop`, and it has to be set as the session
user -- over `sudo`, waydroid cannot see the session and reports "session is
stopped" while appearing to succeed.

### Why not a nested gamescope

It works, but Steam raises its on-screen keyboard for one. Measured, not
assumed: a nested gamescope popped the keyboard with `--expose-wayland`,
without it, and with its window tagged `STEAM_GAME` (verified applied); a bare
`sleep` and cage-on-X11 did not. Dropping gamescope also removes the Gamescope
WSI Vulkan layer conflict (a modal error dialog that blocked rendering) and
`gamescopereaper`, which kills its parent's entire process group.

## Known issues

- **Steam's on-screen keyboard still appears** for the shortcut on some
  systems. Ruled out: Android's IME (`mShowRequested=false`), the Vulkan error
  dialog, the controller layout, `AllowDesktopConfig`, and `STEAM_GAME`.
- **Thin black bars** may remain at the screen edges. A capture of the
  composited output (`gamescopectl screenshot`) shows a full-width 1280x800
  image, so any remaining border is applied after compositing -- check Steam's
  per-shortcut **Scaling Mode** under Quick Access → Performance.
- The Android home screen is briefly visible before the app comes forward.

## Troubleshooting

```bash
deckdroid doctor          # kernel, binder, bundle, sudoers, build id
deckdroid kill            # tear down a stuck launch; only ever touches our own
                          # compositor, never the Game Mode session
cat ~/Android_Waydroid/launch.log     # Steam discards a shortcut's output
gamescopectl screenshot /tmp/shot.png # what is actually on screen
```

Two shell traps caused several silent failures here and are worth knowing about
if you edit these scripts: `grep` exits 1 when it matches nothing, which under
`set -euo pipefail` aborts the whole launcher; and `waydroid shell` needs root
while `waydroid prop`/`session` need the session user.

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
