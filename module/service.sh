#!/system/bin/sh

# Module-level service script. It runs on KernelSU and APatch, and on the
# Magisk family when the built-in Zygisk engine is enabled. External
# providers on the Magisk family are covered by common/service.sh (some of
# them, like ReZygisk, also run this script themselves; the stage lock keeps
# the work from happening twice).

MODDIR=${0%/*}
. "$MODDIR/util.sh"

take_stage_lock service || exit 0

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
until [ -d "/sdcard/Android" ]; do sleep 1; done

ensure_zygisk_injection

# The companion always reads the map from the installed module directory.
MAPDIR=$REVANCED_DIR
[ -d "$MAPDIR" ] || MAPDIR=$MODDIR

# Phase 1: sweep anything left over from the previous boot and write the map.
create_procs_map "$MAPDIR"

# Phase 2: the official modules mount at boot_completed + ~5s. Some root
# managers build their module list before the post-fs-data scripts run, so
# a module disabled there can still mount once. Watch mountinfo for a short
# while and remove the mount as soon as it shows up; the loop is bounded so
# nothing keeps running after boot.
_rv_i=0
while [ "$_rv_i" -lt 15 ]; do
	sleep 1
	_rv_i=$((_rv_i + 1))
	sweep_revanced_mounts
done
