#!/system/bin/sh

. "$MODPATH/util.sh"

if [ -n "$APATCH" ]; then
	rv_print "* APatch detected. Make sure a Zygisk provider is installed"
	rv_print "  (Zygisk Next, NeoZygisk, ReZygisk or Treat Wheel)."
elif [ -n "$KSU" ]; then
	rv_print "* KernelSU detected. Make sure a Zygisk provider is installed"
	rv_print "  (Zygisk Next, NeoZygisk, ReZygisk or Treat Wheel)."
fi

if [ -z "$(collect_revanced_modules)" ]; then
	rv_print "* No official ReVanced Manager module is installed."
	rv_print "  Install the patched app first, then flash this module."
	abort ""
fi

chmod -R +x "$MODPATH/bin"
ensure_zygisk_injection
P=/data/adb/modules/revanced-zygisk-mount
if [ -d "$P" ]; then
	create_procs_map "$P"
fi

# The module-level boot scripts cover KernelSU, APatch, and the Magisk
# family with the built-in Zygisk engine on. With the built-in engine off
# (required by external providers such as Zygisk Next, NeoZygisk, ReZygisk
# and Treat Wheel) Magisk ignores every module that ships a zygisk/ folder,
# so those scripts never run: the common copies below cover that case and
# stay out of the way everywhere else.
mkdir -p /data/adb/post-fs-data.d /data/adb/service.d
cp -f "$MODPATH/common/post-fs-data.sh" /data/adb/post-fs-data.d/revanced-zygisk-mount.sh
cp -f "$MODPATH/common/service.sh" /data/adb/service.d/revanced-zygisk-mount.sh
chmod 0755 /data/adb/post-fs-data.d/revanced-zygisk-mount.sh
chmod 0755 /data/adb/service.d/revanced-zygisk-mount.sh
chmod 0755 "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" "$MODPATH/uninstall.sh"

REAPPLY=/data/data/com.termux/files/usr/bin/
if [ -d "$REAPPLY" ]; then
	echo "su -c '/data/adb/service.d/revanced-zygisk-mount.sh --manual'; echo Done.;" >"$REAPPLY/revanced-zygisk-mount"
	chmod 777 "$REAPPLY/revanced-zygisk-mount"
fi

rv_print "* Done"
rv_print "  based on rvmm-zygisk-mount by j-hc, with fixes from shamrat05"
