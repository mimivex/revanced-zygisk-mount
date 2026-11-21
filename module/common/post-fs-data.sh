#!/system/bin/sh

# Installed as /data/adb/post-fs-data.d/revanced-zygisk-mount.sh by
# customize.sh. This copy exists for the Magisk family when the built-in
# Zygisk engine is off, which is the configuration external providers
# require (Zygisk Next, NeoZygisk, ReZygisk, Treat Wheel): collect_modules()
# then ignores every module that ships a zygisk/ folder, so the module's own
# post-fs-data.sh never runs. KernelSU and APatch always run that script, so
# this copy stays out of the way there.
#
# It runs before Magisk collects the module list, so the official modules are
# not collected at all and their service.sh never mounts globally this boot.

MODDIR=/data/adb/modules_update/revanced-zygisk-mount
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/revanced-zygisk-mount

if [ ! -d "$MODDIR" ]; then
	# The module is gone: remove this leftover script.
	rm -f "$0"
	exit 0
fi

[ -f /data/adb/modules/revanced-zygisk-mount/disable ] && exit 0
[ -f /data/adb/modules_update/revanced-zygisk-mount/disable ] && exit 0

. "$MODDIR/util.sh"

module_scripts_will_run && exit 0
take_stage_lock post-fs-data || exit 0

disable_revanced_modules
