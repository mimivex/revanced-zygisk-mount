#!/system/bin/sh

# Sourced by the installer, the boot scripts and the common copies in
# /data/adb, so no helper may assume MODPATH is set.
#
# Only modules created by the official ReVanced Manager are handled:
#   - module.prop with id=<pkg>-ReVanced (or author=ReVanced)
#   - exactly one <package>.apk in the module root
#   - service.sh that bind mounts it globally after boot_completed
# The patched APK is re-mounted per process by the Zygisk companion instead.

REVANCED_ID=revanced-zygisk-mount
REVANCED_DIR=/data/adb/modules/$REVANCED_ID
REVANCED_STAGED=/data/adb/modules_update/$REVANCED_ID

# Magisk defines ui_print only inside the installer. Boot scripts get a
# logger that also writes to logcat, so the decisions taken at boot
# (engine detected, list cleanup, map entries) can be inspected with
# `adb logcat -s revanced-zygisk-mount` without a root shell.
if ! command -v ui_print >/dev/null 2>&1; then
	ui_print() {
		echo "$REVANCED_ID: $*"
		if command -v log >/dev/null 2>&1; then
			log -t "$REVANCED_ID" "$*" 2>/dev/null || :
		fi
	}
fi

# The installer console does not wrap long lines, so a line wider than the
# window has to be scrolled sideways. Break it on spaces here instead.
rv_print() {
	if ! command -v fold >/dev/null 2>&1; then
		ui_print "$1"
		return 0
	fi
	_rv_first=1
	printf '%s\n' "$1" | fold -s -w 52 | sed 's/[[:space:]]*$//' | while IFS= read -r _rv_line; do
		if [ "$_rv_first" = 1 ]; then
			_rv_first=0
			ui_print "$_rv_line"
		else
			ui_print "  $_rv_line"
		fi
	done
}

is_revanced_module() {
	[ -d "$1" ] || return 1
	[ -f "$1/module.prop" ] || return 1

	if ! grep -Eiq '^id=.*-revanced[[:space:]]*$' "$1/module.prop" &&
		! grep -Eiq '^author=revanced[[:space:]]*$' "$1/module.prop"; then
		return 1
	fi

	_rv_count=0
	for _rv_file in "$1"/*.apk; do
		[ -f "$_rv_file" ] && _rv_count=$((_rv_count + 1))
	done
	[ "$_rv_count" -eq 1 ]
}

revanced_pkg_name() {
	for _rv_file in "$1"/*.apk; do
		[ -f "$_rv_file" ] || continue
		_rv_file=${_rv_file##*/}
		echo "${_rv_file%.apk}"
		return 0
	done
	return 1
}

collect_revanced_modules() {
	for _rv_path in /data/adb/modules_update/*; do
		is_revanced_module "$_rv_path" || continue
		_rv_installed=$(echo "$_rv_path" | sed 's/modules_update/modules/')
		[ -f "$_rv_installed/remove" ] && continue
		echo "$_rv_path"
	done

	for _rv_path in /data/adb/modules/*; do
		is_revanced_module "$_rv_path" || continue
		[ -f "$_rv_path/remove" ] && continue
		_rv_staged=$(echo "$_rv_path" | sed 's/modules/modules_update/')
		[ -d "$_rv_staged" ] && continue
		echo "$_rv_path"
	done
}

revanced_arch() {
	case "${ARCH:-$(getprop ro.product.cpu.abi)}" in
		arm|armeabi|armeabi-v7a) echo arm ;;
		arm64|arm64-v8a) echo arm64 ;;
		x86) echo x86 ;;
		x64|x86_64) echo x64 ;;
		*) echo arm64 ;;
	esac
}

enable_revanced_modules() {
	collect_revanced_modules | while IFS= read -r _rv_path; do
		[ -f "$_rv_path/err" ] || continue
		rm -f "$_rv_path/disable"
		mv -f "$_rv_path/err" "$_rv_path/module.prop"
	done
}

# Stops the official modules from mounting globally. The common post-fs-data
# script calls this before Magisk builds its module list, so their service.sh
# does not run at all in the current boot. Without a Zygisk engine there is
# nothing that could take over the mount, so the official modules are left
# enabled and the app keeps working the stock way.
disable_revanced_modules() {
	if [ "$(zygisk_provider)" = "none" ]; then
		rv_print "WARNING: no Zygisk engine found; leaving the official modules enabled"
		return 0
	fi

	collect_revanced_modules | while IFS= read -r _rv_path; do
		# Already disabled by the user: leave it alone, it never mounts.
		[ -f "$_rv_path/disable" ] && continue
		: >"$_rv_path/disable"
		[ -f "$_rv_path/err" ] || cp -f "$_rv_path/module.prop" "$_rv_path/err"
		sed -i "s/^des.*/description=⚠️ Keep this module disabled. Mounting is being handled by revanced-zygisk-mount./g" "$_rv_path/module.prop"
	done
}

# Removes the global bind mount left behind by the official modules.
#
# /proc/mounts only reports the device of a bind mount, never the source
# path, so read the root field of mountinfo instead. That root is relative
# to the filesystem the source lives on: /data is its own mount, so a bind
# from /data/adb/modules/... is listed as /adb/modules/...; match the
# modules component rather than the full path. Matching on the package name
# alone would also hit the system's own mounts such as /data/data/<pkg>.
sweep_revanced_mounts() {
	collect_revanced_modules | while IFS= read -r _rv_path; do
		_rv_pkg=$(revanced_pkg_name "$_rv_path")
		[ -n "$_rv_pkg" ] || continue

		_rv_swept=0
		while read -r _rv_id _rv_parent _rv_dev _rv_root _rv_target _rv_rest; do
			case "$_rv_root" in
				*/modules/*/"$_rv_pkg".apk|*/modules_update/*/"$_rv_pkg".apk)
					rv_print "* Unmount '$_rv_target'"
					umount -l "$_rv_target"
					_rv_swept=1
					;;
			esac
		done </proc/self/mountinfo

		# The app may still hold the old global mount: restart it so it
		# picks up the per-process one. When there is nothing to unmount
		# the app is left alone, so it keeps auto-starting normally.
		[ "$_rv_swept" = 1 ] && am force-stop "$_rv_pkg" 2>/dev/null
	done
}

# Removes the global mounts and rebuilds procs_map with
# {process, apk, base.apk} triples for the companion.
create_procs_map() {
	if [ "$(zygisk_provider)" = "none" ]; then
		rv_print "WARNING: no Zygisk engine found; leaving the global mounts alone"
		return 0
	fi

	sweep_revanced_mounts

	_rv_moddir=$1
	_rv_map="$_rv_moddir/procs_map"
	_rv_tmp="$_rv_map.tmp.$$"
	: >"$_rv_tmp"

	collect_revanced_modules | while IFS= read -r _rv_path; do
		_rv_pkg=$(revanced_pkg_name "$_rv_path")
		[ -n "$_rv_pkg" ] || continue

		_rv_apk="$_rv_path/$_rv_pkg.apk"
		[ -f "$_rv_apk" ] || continue

		# Never mount a patched APK built for a different app version.
		_rv_module_ver=$(grep -m1 '^version=' "$_rv_path/module.prop" 2>/dev/null | cut -d= -f2-)
		_rv_app_ver=$(dumpsys package "$_rv_pkg" 2>/dev/null | grep -m1 'versionName=' | cut -d= -f2)
		if [ -n "$_rv_module_ver" ] && [ -n "$_rv_app_ver" ] && [ "$_rv_module_ver" != "$_rv_app_ver" ]; then
			rv_print "ERROR: $_rv_pkg is version $_rv_app_ver but the patched module is $_rv_module_ver; skipping"
			continue
		fi

		# The official module never relabels its APK; without this the app
		# gets an SELinux denial once the APK is bind mounted over base.apk.
		chcon u:object_r:apk_data_file:s0 "$_rv_apk" 2>/dev/null || true

		_rv_base=$(pm path "$_rv_pkg" 2>/dev/null </dev/null | grep -m1 base | sed 's/^package://')
		if [ -z "$_rv_base" ]; then
			rv_print "ERROR: $_rv_pkg is not installed. Re-flash its module and do not reboot."
			continue
		fi

		for _rv_str in "$_rv_pkg" "$_rv_apk" "$_rv_base"; do
			printf '%b%s\0' "\\x$(printf '%02x' "${#_rv_str}")" "$_rv_str" >>"$_rv_tmp"
		done
		rv_print "* Applied for $_rv_pkg"
	done
	printf '\0' >>"$_rv_tmp"

	# Rename in place so the companion never reads a half written map.
	mv -f "$_rv_tmp" "$_rv_map"
}

# `magisk magiskhide sulist` exists only on Kitsune/Magisk Delta. Its exit
# code is 1 both when SuList is off and on a build without the applet, so the
# status line is the reliable marker.
sulist_enforced() {
	magisk magiskhide sulist 2>&1 | grep -q '^SuList is enforced'
}

# Which command reaches the hide list on this build. Kitsune and Tanuki
# ship the magiskhide applet, stock Magisk only has --denylist, and a build
# can expose both, so trust what answers instead of the manager's name.
hide_list_backend() {
	if magisk magiskhide sulist 2>&1 | grep -q '^SuList is '; then
		# The SuList is the active table, so the applet is the right one.
		echo magiskhide
	elif magisk --denylist ls >/dev/null 2>&1; then
		echo denylist
	elif magisk magiskhide ls >/dev/null 2>&1; then
		echo magiskhide
	else
		echo none
	fi
}

root_manager() {
	if [ -n "${APATCH:-}" ]; then
		echo "APatch"
	elif [ -n "${KSU:-}" ]; then
		echo "KernelSU"
	elif [ ! -d /data/adb/magisk ]; then
		echo "unknown root manager"
	elif magisk magiskhide sulist 2>&1 | grep -q '^SuList is '; then
		echo "Magisk family (Kitsune-style applet)"
	else
		echo "Magisk family"
	fi
}

list_has() {
	case "$(hide_list_backend)" in
		denylist) _rv_out=$(magisk --denylist ls 2>/dev/null) ;;
		magiskhide) _rv_out=$(magisk magiskhide ls 2>/dev/null) ;;
		*) return 1 ;;
	esac
	echo "$_rv_out" | tr '|' '\n' | grep -Fxq "$1"
}

list_remove() {
	case "$(hide_list_backend)" in
		denylist) magisk --denylist rm "$1" >/dev/null 2>&1 ;;
		magiskhide) magisk magiskhide rm "$1" >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}

# Serializes the module script and the common script of the same boot stage.
# External providers such as ReZygisk run the service.sh of Zygisk modules
# themselves on top of the common script, so the work would otherwise happen
# twice. The lock lives in /dev (tmpfs, cleared on reboot) and is released on
# exit so a manual re-run from Termux keeps working.
take_stage_lock() {
	_rv_lock="/dev/revanced-zygisk-mount.$1.lock"
	if mkdir "$_rv_lock" 2>/dev/null; then
		trap 'rmdir "$_rv_lock" 2>/dev/null' EXIT
		return 0
	fi
	# The directory already exists: another copy of this stage is running.
	[ -d "$_rv_lock" ] && return 1
	# /dev is not writable: do the work anyway, the lock is best effort.
	return 0
}

# True when the root manager also runs this module's own boot scripts, in
# which case the common copies must do nothing:
#   - KernelSU and APatch always run module scripts
#   - the Magisk family runs them only when its built-in Zygisk engine is on:
#     collect_modules() ignores every module that ships a zygisk/ folder
#     whenever the engine is off, which is the case external providers
#     require (Zygisk Next, NeoZygisk, ReZygisk, Treat Wheel)
# Magisk reads the Zygisk setting after it runs the common post-fs-data
# scripts, so ZYGISK_ENABLED is not exported yet during that stage: ask the
# database instead.
module_scripts_will_run() {
	[ -n "${KSU:-}" ] && return 0
	[ -n "${APATCH:-}" ] && return 0
	[ -d /data/adb/magisk ] || return 1
	magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null | grep -q '=1$'
}

# Prints the Zygisk engine that injects the companion:
#   built-in Zygisk, Zygisk Next, NeoZygisk, ZNNext, ReZygisk, Treat Wheel,
#   external Zygisk provider (unrecognized module shipping a Zygisk library)
#   or none.
#
# Magisk exports ZYGISK_ENABLED only when its own engine is enabled. With an
# external provider the built-in engine stays off, Magisk then ignores this
# module because it ships a zygisk/ folder, and its module-level scripts
# never run; the common scripts cover that case.
zygisk_provider() {
	if [ "${ZYGISK_ENABLED:-0}" = 1 ]; then
		echo "built-in Zygisk"
		return 0
	fi

	for _rv_path in /data/adb/modules/*; do
		[ -d "$_rv_path" ] || continue
		[ -f "$_rv_path/disable" ] && continue
		[ -f "$_rv_path/remove" ] && continue
		[ "$_rv_path" = "$REVANCED_DIR" ] && continue
		case "${_rv_path##*/}" in
			zygisksu)
				# Module id shared by Zygisk Next and NeoZygisk.
				_rv_name=$(grep -m1 '^name=' "$_rv_path/module.prop" 2>/dev/null | cut -d= -f2-)
				echo "${_rv_name:-Zygisk Next}"
				return 0
				;;
			zygisknextsu) echo "ZNNext"; return 0 ;;
			rezygisk) echo "ReZygisk"; return 0 ;;
			treat_wheel) echo "Treat Wheel"; return 0 ;;
		esac
	done

	# Outside boot scripts (customize.sh, uninstall.sh) the environment is
	# not set, so ask Magisk directly.
	if magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null | grep -q '=1$'; then
		echo "built-in Zygisk"
		return 0
	fi

	# Any other enabled module shipping a Zygisk library is a provider too.
	# The known hiding modules are skipped: they need an engine themselves.
	for _rv_path in /data/adb/modules/*; do
		[ -d "$_rv_path" ] || continue
		[ -f "$_rv_path/disable" ] && continue
		[ -f "$_rv_path/remove" ] && continue
		[ "$_rv_path" = "$REVANCED_DIR" ] && continue
		case "${_rv_path##*/}" in
			shamiko|zygisk_nohello|zygisk-assistant) continue ;;
		esac
		set -- "$_rv_path"/zygisk/*.so
		[ -e "$1" ] && {
			echo "external Zygisk provider"
			return 0
		}
	done

	echo "none"
}

drop_from_magisk_lists() {
	_rv_backend=$(hide_list_backend)
	if [ "$_rv_backend" = none ]; then
		rv_print "* No hide list command found; leaving Magisk lists untouched"
		return 0
	fi
	list_has "$1" || return 0

	list_remove "$1" || return 0
	if [ "$_rv_backend" = magiskhide ]; then
		if sulist_enforced; then
			_rv_name=SuList
		else
			_rv_name=MagiskHide list
		fi
	else
		_rv_name=denylist
	fi
	rv_print "* Removed $1 from the $_rv_name"
}

# Makes sure the active Zygisk engine will be injected into the patched apps:
#  - KernelSU: mark the app for unmounting through ksu_profile
#  - APatch: nothing to script, excluded apps are managed in its own UI
#  - built-in Zygisk: the app must not be on the MagiskHide/denylist, because
#    stock Magisk skips Zygisk modules for those targets. The SuList is left
#    alone: it only decides who can reach root, injection happens either way.
#  - external provider (Zygisk Next, NeoZygisk, ReZygisk, Treat Wheel, ...):
#    clear the app from whatever list is active, because the provider ignores
#    the list but root still follows it
ensure_zygisk_injection() {
	_rv_bindir="${MODPATH:-$MODDIR}/bin/$(revanced_arch)"
	_rv_provider=$(zygisk_provider)
	_rv_backend=$(hide_list_backend)

	# The boot log opens with the module version, so the installed build is
	# identifiable from logcat.
	_rv_ver=$(grep -m1 '^version=' "${MODPATH:-$MODDIR}/module.prop" 2>/dev/null | cut -d= -f2-)
	rv_print "* Module: revanced-zygisk-mount ${_rv_ver:-unknown}"

	rv_print "* Config: $(root_manager); engine: $_rv_provider; hide list: $_rv_backend"

	if [ "$_rv_provider" = "none" ]; then
		rv_print "  WARNING: no Zygisk engine detected. Install Zygisk Next,"
		rv_print "  NeoZygisk, ReZygisk or Treat Wheel, or enable the built-in"
		rv_print "  Zygisk engine, then reboot. No need to re-flash this module."
		return 0
	fi

	# Say once what the per-app step is going to do, so the log explains
	# itself without the user having to read the script.
	if [ -n "${APATCH:-}" ]; then
		_rv_mode="APatch: per-app exclusions are managed in APatch itself"
	elif [ -n "${KSU:-}" ]; then
		_rv_mode="KernelSU: apps registered with ksu_profile"
	elif [ "$_rv_provider" = "built-in Zygisk" ]; then
		if sulist_enforced; then
			_rv_mode="built-in Zygisk: SuList left alone"
		else
			_rv_mode="built-in Zygisk: apps removed from the hide list"
		fi
	else
		_rv_mode="$_rv_provider: apps removed from the hide list"
	fi
	rv_print "* Mode: $_rv_mode"

	collect_revanced_modules | while IFS= read -r _rv_path; do
		_rv_pkg=$(revanced_pkg_name "$_rv_path")
		[ -n "$_rv_pkg" ] || continue

		if [ -n "${APATCH:-}" ]; then
			# APatch has no scriptable per-app module exclusion.
			:
		elif [ -n "${KSU:-}" ]; then
			_rv_uid=$(dumpsys package "$_rv_pkg" 2>/dev/null | grep -m1 'userId=' | cut -d= -f2 | tr -d ' ')
			if [ -z "$_rv_uid" ]; then
				_rv_uid=$(dumpsys package "$_rv_pkg" 2>/dev/null | grep -m1 'uid=' | cut -d= -f2 | tr -d ' ')
			fi
			if [ -z "$_rv_uid" ]; then
				rv_print "* UID could not be found for $_rv_pkg"
				continue
			fi
			if ! _rv_out=$("$_rv_bindir/ksu_profile" "$_rv_uid" "$_rv_pkg" 2>&1); then
				rv_print "ERROR ksu_profile: $_rv_out"
			fi
		elif [ "$_rv_provider" = "built-in Zygisk" ]; then
			# The SuList only decides who can reach root; Zygisk modules are
			# injected into every process except the manager, so an app on it
			# gains nothing and an app off it still gets the mount.
			if ! sulist_enforced && list_has "$_rv_pkg"; then
				list_remove "$_rv_pkg"
				rv_print "* Removed $_rv_pkg from the hide list"
			fi
		else
			drop_from_magisk_lists "$_rv_pkg" "$_rv_provider"
		fi
	done

	return 0
}
