# Kernel support

Waydroid needs the kernel's Android binder driver. Valve does not enable it
consistently across the `linux-neptune` series, so whether Waydroid can run at
all is decided by which kernel your SteamOS build ships.

Read straight from Valve's published kernel configs:

| neptune series | kernel   | `CONFIG_ANDROID_BINDER_IPC` |
| -------------- | -------- | --------------------------- |
| 68             | 6.8.12   | not set                     |
| 611            | 6.11.11  | not set                     |
| 615            | 6.15.11  | **=y** (with binderfs)      |
| 616            | 6.16.12  | **=y** (with binderfs)      |
| 618            | 6.18.46  | not set                     |
| 72             | 7.2.0    | not set                     |

SteamOS **3.8.16** ships kernel **6.16.12**, which has it. That is currently the
newest image offered on every channel, so "update to the latest SteamOS" is the
right instruction today.

Check your own machine:

```bash
zgrep CONFIG_ANDROID_BINDER /proc/config.gz
grep binder /proc/filesystems      # 'nodev binder' means binderfs is ready
```

`CONFIG_ANDROID_BINDER_DEVICES` is empty even where binder is enabled. That is
fine: Waydroid detects binderfs, mounts it at `/dev/binderfs`, and creates the
`binder`/`hwbinder`/`vndbinder` nodes itself with the `BINDER_CTL_ADD` ioctl.

## If a future SteamOS drops binder again

Note that 6.18 and 7.2 are *newer* than 6.16 and do not have it, so this is not
a setting you can assume will stay. If an update lands on such a kernel,
deckdroid will refuse to start and say so rather than failing obscurely.

The fix would be an out-of-tree `binder_linux` module built against the running
kernel. That is viable — Valve publishes headers for every kernel at
`steamdeck-packages.steamos.cloud`, and `CONFIG_MODULE_SIG_FORCE` is not set, so
an unsigned module loads. It is deliberately not implemented yet, because on
6.16 there is nothing to build.
