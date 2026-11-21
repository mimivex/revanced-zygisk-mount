# revanced-zygisk-mount

Hides the bind mounts created by modules from the **official ReVanced Manager**.

The modules produced by [ReVanced Manager](https://github.com/revanced/revanced-manager) (`/<pkg>-ReVanced` in `/data/adb/modules`)
bind mount the patched APK over the stock one with a plain global
`mount -o bind` from `service.sh`. That mount is visible in `/proc/mounts` to
every app and root detector.

This module takes over the job by creating a private namespace and letting the Zygisk companion mount the patched APK there.


## Requirements

- Any of **Magisk**, **KernelSU** or
  **APatch**
- A Zygisk engine
- The app must already be patched and installed with the "Mount" option through the official ReVanced Manager
- The patched app must **not** be in the denylist, or Zygisk will not inject into it. If it is, this module removes it and logs that it did during module installation.

If no Zygisk engine is detected, the module leaves the official modules enabled and the global mounts alone, so the app keeps working the stock way. The engine is detected again at every boot, so installing one later only needs a reboot; there is nothing to re-flash.

## Root manager and Zygisk engine compatibility

Magisk and its forks skip every module that ships a top-level `zygisk/`
folder when their **built-in Zygisk engine is off**. Their `post-fs-data.sh`
and `service.sh` are never run in that case. To work everywhere, the module
uses two complementary entry points, serialized so the work never happens
twice:

| Root solution | Zygisk engine | Boot entry point |
| --- | --- | --- |
| Magisk, Kitsune, Tanuki | built-in Zygisk (**on**) | module `post-fs-data.sh` + `service.sh` |
| Magisk, Kitsune, Tanuki | external provider (built-in **off**) | `/data/adb/post-fs-data.d/revanced-zygisk-mount.sh` + `/data/adb/service.d/revanced-zygisk-mount.sh` |
| KernelSU | external provider | module `post-fs-data.sh` + `service.sh` |
| APatch | external provider | module `post-fs-data.sh` + `service.sh` |

Classic Magisk is supported exactly like the forks: nothing depends on
`boot-completed.sh` or an init.rc hook. The module scripts, the common
`post-fs-data.d`/`service.d` copies and a poll of `sys.boot_completed` are all
it needs.

The hide list is also detected at runtime rather than assumed from the
manager name:

1. `magisk magiskhide sulist` printing a status line → the applet is used, and
   the active table is the SuList when it is enforced;
2. otherwise `magisk --denylist ls` → the stock denylist;
3. otherwise `magisk magiskhide ls` → the applet in MagiskHide mode;
4. if none of them answers, the lists are left untouched and the log says so.

Stock Magisk only has `--denylist`, Kitsune replaced it with the `magiskhide`
applet, and Tanuki has both. The probe order above picks whichever one
answers, so any build that exposes one verb or the other works too. Install
and boot print the result once, e.g.:

```text
* Config: Magisk family (Kitsune-style applet); engine: Zygisk Next; hide list: magiskhide
* Mode: Zygisk Next: apps removed from the hide list
```

- **Magisk family**: the common scripts exit immediately when the built-in
  engine is on. When it is off, they do the work and run before Magisk
  collects the module list, so the official modules are disabled before
  their `service.sh` can be collected.
- **KernelSU**: the patched app is registered with `ksu_profile` so its
  module mounts are unmounted for that process.
- **APatch**: module boot scripts run normally; per-app module exclusions
  are managed in APatch's own UI.
- **Kitsune SuList**: it decides who can reach root, not who gets Zygisk
  modules. With the built-in engine on, modules are injected into every
  process except the manager, so the SuList is left alone and an app already
  on it stays there. The MagiskHide/denylist is different: stock Magisk skips
  Zygisk modules for those targets, so the app is removed from it when it is
  listed. With an external provider the app is removed from whatever list is
  active, the SuList included, because the provider ignores the list but root
  still follows it. An entry is only removed when it actually exists, and the
  log names the list it came from.

## Installation

1. Patch and install the app with ReVanced Manager as usual.
2. Flash [`revanced-zygisk-mount.zip`](https://github.com/mimivex/revanced-zygisk-mount/releases/latest) and reboot.
3. Wait a few seconds after boot before checking anything. Some root
   managers build their module list before the `post-fs-data` scripts run,
   so an official module disabled there can still mount once; the service
   stage watches mountinfo for 15 seconds after `boot_completed` and removes
   that mount as soon as it appears.

The official modules are disabled automatically. Their original
`module.prop` is saved as `err`, and the description is rewritten so the
state is obvious in the Magisk app.

To go back to the official modules, uninstall this module: `uninstall.sh`
removes the common copies and re-enables them, restoring `module.prop` from
`err`. To do it by hand, delete `disable` in each ReVanced module directory
and restore `module.prop` from `err`.

## Notes

- Zygisk injects this module into every app process it spawns, so a module
  log line is not a sign that something is wrong. Processes that are not in
  the map are ignored without writing anything.
- The companion mounts only after the app has left the mount namespace it
  shared with zygote. Until then it waits, because a bind mounted in the
  shared namespace would be inherited by every app started afterwards. If the
  process never gets a namespace of its own the mount is skipped and the log
  says so, instead of exposing it.
- After updating the app, reboot (or run the `revanced-zygisk-mount` helper
  the installer drops in Termux, or the module's `service.sh` directly) so
  the map points at the new `base.apk`.
- Patching or installing an app from ReVanced Manager while the phone is
  running makes the Manager create a new global mount right away. It is
  removed at the next boot, together with the app's restart; until then the
  mount is visible. Reboot after patching a new app.
- Only modules with exactly one `<package>.apk` in their root are handled,
  which is what ReVanced Manager produces; split/multi-APK modules are
  skipped.
- The module never mounts a patched APK whose `version=` does not match the
  installed app version.
- Re-flashing an app from ReVanced Manager creates a fresh module directory
  without `disable`; it is disabled again at the next `post-fs-data`. On that
  first boot the global mount can be visible for a few seconds.
- Disabling this module leaves the official modules disabled, because no
  boot script runs to give them back. Uninstall it to restore their global
  mounts.

## Credits

This repository is a fork of
[shamrat05/rvmm-zygisk-mount](https://github.com/shamrat05/rvmm-zygisk-mount),
itself a fork of
[j-hc/rvmm-zygisk-mount](https://github.com/j-hc/rvmm-zygisk-mount).

- **j-hc** — [github.com/j-hc](https://github.com/j-hc) — original
  `rvmm-zygisk-mount` design and the Zygisk per-process mount approach
  ([project](https://github.com/j-hc/rvmm-zygisk-mount)), plus the
  [`ksu_profile`](https://github.com/j-hc/ksu_profile) helper used on
  KernelSU.
- **shamrat05** — [github.com/shamrat05](https://github.com/shamrat05) — the
  [fork](https://github.com/shamrat05/rvmm-zygisk-mount) this module is based
  on ([v13](https://github.com/shamrat05/rvmm-zygisk-mount/releases/tag/v13)):
  use-after-free fix in the companion handoff, partial socket read/write
  handling, Zygisk Next null process-name guard and static libc++ linking.
- **topjohnwu** — [github.com/topjohnwu](https://github.com/topjohnwu) — the
  [`zygisk-module-sample`](https://github.com/topjohnwu/zygisk-module-sample)
  header `zygisk/jni/zygisk.hpp`.

## License

Apache-2.0, see [LICENSE](LICENSE).

The bundled `zygisk/jni/zygisk.hpp` is Copyright 2022-2023 John "topjohnwu"
Wu and carries its own permissive license at the top of the file.
