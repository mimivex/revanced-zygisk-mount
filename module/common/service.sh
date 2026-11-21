#!/system/bin/sh

# Installed as /data/adb/service.d/revanced-zygisk-mount.sh by customize.sh.
# Same rationale as common/post-fs-data.sh: this copy runs only on the Magisk
# family with the built-in Zygisk engine off, where the module's own
# service.sh is ignored. External providers such as ReZygisk may also run
# that service.sh themselves, hence the stage lock.

MODDIR=/data/adb/modules_update/revanced-zygisk-mount
[ -f "$MODDIR/util.sh" ] || MODDIR=/data/adb/modules/revanced-zygisk-mount

if [ ! -f "$MODDIR/util.sh" ]; then
	# The module is gone: remove this leftover script.
	rm -f "$0"
	exit 0
fi

[ -f /data/adb/modules/revanced-zygisk-mount/disable ] && exit 0
[ -f /data/adb/modules_update/revanced-zygisk-mount/disable ] && exit 0

. "$MODDIR/util.sh"

# The Termux helper calls this script with --manual, where the work must
# happen even if the module's own boot scripts are the primary path.
if [ "${1:-}" != "--manual" ]; then
	module_scripts_will_run && exit 0
fi
take_stage_lock service || exit 0

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
until [ -d "/sdcard/Android" ]; do sleep 1; done

ensure_zygisk_injection

# The companion reads the map from the installed module directory.
MAPDIR=$REVANCED_DIR
[ -d "$MAPDIR" ] || MAPDIR=$MODDIR

# Phase 1: sweep anything left over from the previous boot and write the map.
create_procs_map "$MAPDIR"

# Phase 2: the official modules mount at boot_completed + ~5s. Some root
# managers build their module list before the post-fs-data scripts run, so
# a module disabled there can still mount once. Watch mountinfo for a short
# while and remove the mount as soon as it shows up; the loop is bounded so
# nothing keeps running after boot. The Termux helper wants the map right
# away, so it skips this part.
if [ "${1:-}" != "--manual" ]; then
	_rv_i=0
	while [ "$_rv_i" -lt 15 ]; do
		sleep 1
		_rv_i=$((_rv_i + 1))
		sweep_revanced_mounts
	done
fi
