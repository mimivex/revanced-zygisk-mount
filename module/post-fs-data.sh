#!/system/bin/sh

# Module-level post-fs-data script. It runs on KernelSU and APatch, and on
# the Magisk family when the built-in Zygisk engine is enabled (with the
# engine off, collect_modules() ignores this module because it ships a
# zygisk/ folder; common/post-fs-data.sh covers that case instead).
#
# Disabling the official modules here happens before Magisk recollects its
# module list, so their service.sh does not run in the current boot.

MODDIR=${0%/*}
. "$MODDIR/util.sh"

take_stage_lock post-fs-data || exit 0

disable_revanced_modules
