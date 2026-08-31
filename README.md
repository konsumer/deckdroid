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

## Android images

Defaults to the **Android TV** builds from
[WayDroid-ATV](https://github.com/WayDroid-ATV/waydroid-androidtv-builds):
LineageOS 23 (Android 16) for `waydroid_tv_x86_64`, with libhoudini ARM
translation, Widevine L3 and VA-API — all of which matter more on a TV build
than the stock phone images.

```bash
deckdroid install --flavor tv-gapps    # Android TV with GApps (default)
deckdroid install --flavor tv           # Android TV, no GApps
deckdroid install --flavor lineage     # stock phone LineageOS from waydroid's OTA
```

Switching later:

```bash
deckdroid images --flavor tv --force
deckdroid reinit --wipe                # data from another build rarely survives
```

Assets are checksummed against the release's published sha256 either way.

GApps is the default because the Play Store is how most TV apps get installed.
A device Google has not seen before cannot sign in, so register it once:

```bash
deckdroid gapps            # prints the device ID and what to do with it
deckdroid gapps --reset    # after registering, clears Play state so it retries
```

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
deckdroid shortcuts sync --all        # include the stock apps too
deckdroid shortcuts remove            # take ours back out
deckdroid launch org.fdroid.fdroid
deckdroid refresh                     # regenerate icons and desktop entries
deckdroid doctor                      # what is wrong, if anything
```

`shortcuts sync` also adds an **Android TV** entry that opens the TV interface
itself, so you can either pick an individual app from Steam or just launch the
launcher and browse from the couch. Beyond that it only picks up apps you
installed: waydroid marks LineageOS's
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

## Controller navigation on TV builds

Android TV interfaces are driven entirely by a D-pad — they have no on-screen
navigation bar and leanback UIs ignore the mouse by design. Arrows and Enter
already reach Android as D-pad and select, but **Back and Home do not**:
Android's `Generic.kl` binds them to Linux key codes `158` and `172`, which no
keyboard has, so Steam Input cannot send them.

`deckdroid keymap` overlays the key layout to put those actions on keys Steam
Input *can* send, then restarts the session:

```
Esc -> BACK      F1 -> HOME      F2 -> APP_SWITCH      F3 -> MENU
```

Then bind, per shortcut (Controller icon → Edit Layout):

| Controller | Key | Does |
| ---------- | --- | ---- |
| D-pad / left stick | Arrow keys | navigate |
| A | Enter | select |
| B | Escape | back |
| Y | F1 | home |
| Select | F2 | recent apps |
| Start | F3 | menu |

The overlay lives in the data image, so it survives restarts but not
`reinit --wipe`; re-run `deckdroid keymap` after wiping.

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
