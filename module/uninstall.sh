#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/util.sh"

# The boot helpers live outside the module directory.
rm -f /data/adb/post-fs-data.d/revanced-zygisk-mount.sh
rm -f /data/adb/service.d/revanced-zygisk-mount.sh

# Give the official modules back: remove the disable flag this module added
# and restore the module.prop saved as err.
enable_revanced_modules
