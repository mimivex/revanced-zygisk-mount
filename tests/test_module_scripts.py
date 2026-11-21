from pathlib import Path
import unittest


MODULE = Path(__file__).parents[1] / "module"


def read(name):
    return (MODULE / name).read_text()


class ModuleScriptTests(unittest.TestCase):
    def setUp(self):
        self.util = read("util.sh")
        self.post_fs_data = read("post-fs-data.sh")
        self.service = read("service.sh")
        self.common_pfd = read("common/post-fs-data.sh")
        self.common_service = read("common/service.sh")
        self.customize = read("customize.sh")
        self.uninstall = read("uninstall.sh")

    def test_kitsune_sulist_is_detected_by_its_status_line(self):
        # `magisk magiskhide sulist` exits 1 both when SuList is off and on a
        # build without the applet, so the status line is the reliable marker.
        self.assertIn("grep -q '^SuList is enforced'", self.util)

    def test_zygisk_providers_are_recognized(self):
        for module_id in ("zygisksu", "zygisknextsu", "rezygisk", "treat_wheel"):
            self.assertIn(f"{module_id})", self.util)
        # zygisksu is shared by Zygisk Next and NeoZygisk; ask module.prop.
        self.assertIn("grep -m1 '^name='", self.util)

    def test_hide_list_backend_is_probed_by_capability(self):
        # Kitsune and Tanuki can expose different verbs, so try them in order
        # and keep the first one that answers.
        body = self.util[self.util.index("hide_list_backend() {"):]
        body = body[:body.index("\n}\n")]
        sulist = body.index("magisk magiskhide sulist")
        denylist = body.index("magisk --denylist ls")
        magiskhide = body.index("magisk magiskhide ls")
        self.assertLess(sulist, denylist)
        self.assertLess(denylist, magiskhide)
        self.assertIn("echo none", body)

    def test_list_helpers_follow_the_detected_backend(self):
        self.assertIn('denylist) _rv_out=$(magisk --denylist ls 2>/dev/null) ;;', self.util)
        self.assertIn('magiskhide) _rv_out=$(magisk magiskhide ls 2>/dev/null) ;;', self.util)
        self.assertIn('denylist) magisk --denylist rm "$1" >/dev/null 2>&1 ;;', self.util)
        self.assertIn('magiskhide) magisk magiskhide rm "$1" >/dev/null 2>&1 ;;', self.util)
        # Every --denylist call lives in the backend helpers above.
        self.assertEqual(self.util.count("magisk --denylist"), 3)

    def test_external_provider_removes_only_existing_entries(self):
        body = self.util[self.util.index("drop_from_magisk_lists() {"):]
        body = body[:body.index("\n}\n")]
        self.assertIn('list_has "$1" || return 0', body)
        self.assertIn('list_remove "$1"', body)
        self.assertLess(body.index("list_has"), body.index("list_remove"))
        self.assertIn("No hide list command found", body)

    def test_config_line_names_root_manager_engine_and_list(self):
        self.assertIn(
            "* Config: $(root_manager); engine: $_rv_provider; hide list: $_rv_backend",
            self.util,
        )
        self.assertIn('rv_print "* Mode: $_rv_mode"', self.util)
        for label in (
            'echo "APatch"',
            'echo "KernelSU"',
            'echo "Magisk family (Kitsune-style applet)"',
            'echo "Magisk family"',
        ):
            self.assertIn(label, self.util)

    def test_module_version_is_logged_before_the_config(self):
        # The boot log must open with the module's own version line so the
        # installed build is identifiable from logcat.
        body = self.util[self.util.index("ensure_zygisk_injection() {"):]
        body = body[:body.index("\n}\n")]
        module = body.index('"* Module: revanced-zygisk-mount ${_rv_ver:-unknown}"')
        config = body.index('"* Config: $(root_manager); engine: $_rv_provider; hide list: $_rv_backend"')
        self.assertLess(module, config)
        self.assertIn("grep -m1 '^version='", body)

    def test_the_sulist_is_never_written_for_the_builtin_engine(self):
        # SuList governs root access, not injection: Kitsune and Tanuki load
        # Zygisk modules into every process except the manager. Adding the app
        # would put a media app in the root whitelist and keep Magisk's mounts
        # visible to it, for no benefit.
        self.assertNotIn("magisk magiskhide add", self.util)
        builtin = self.util[self.util.index('elif [ "$_rv_provider" = "built-in Zygisk" ]; then'):]
        branch = builtin[:builtin.index("drop_from_magisk_lists")]
        self.assertIn("! sulist_enforced", branch)
        self.assertIn('list_remove "$_rv_pkg"', branch)

    def test_kernelsu_and_apatch_never_go_through_magisk_lists(self):
        apatch = 'if [ -n "${APATCH:-}" ]; then'
        ksu = 'elif [ -n "${KSU:-}" ]; then'
        builtin = 'elif [ "$_rv_provider" = "built-in Zygisk" ]; then'
        self.assertLess(self.util.index(apatch), self.util.index(ksu))
        self.assertLess(self.util.index(ksu), self.util.index(builtin))

    def test_common_scripts_yield_to_the_module_scripts(self):
        # With KernelSU/APatch, or with Magisk's built-in Zygisk on, the
        # module's own boot scripts run and the common copies must not.
        self.assertIn("module_scripts_will_run && exit 0", self.common_pfd)
        self.assertIn("module_scripts_will_run && exit 0", self.common_service)
        self.assertIn('[ -n "${KSU:-}" ] && return 0', self.util)
        self.assertIn('[ -n "${APATCH:-}" ] && return 0', self.util)
        self.assertIn("[ -d /data/adb/magisk ]", self.util)
        self.assertIn("key='zygisk'", self.util)

    def test_boot_scripts_log_their_decisions_to_logcat(self):
        # Script output never reaches logcat on its own, and the user cannot
        # be assumed to have a root shell; mirror ui_print into logcat.
        self.assertIn('log -t "$REVANCED_ID"', self.util)
        self.assertIn('command -v log', self.util)

    def test_boot_stages_are_serialized_between_the_two_copies(self):
        # External providers such as ReZygisk run the module's service.sh
        # themselves on top of the common script.
        for script in (self.post_fs_data, self.common_pfd):
            self.assertIn("take_stage_lock post-fs-data", script)
        for script in (self.service, self.common_service):
            self.assertIn("take_stage_lock service", script)

    def test_common_scripts_are_installed_and_removed(self):
        self.assertIn("/data/adb/post-fs-data.d/revanced-zygisk-mount.sh", self.customize)
        self.assertIn("/data/adb/service.d/revanced-zygisk-mount.sh", self.customize)
        self.assertIn("rm -f /data/adb/post-fs-data.d/revanced-zygisk-mount.sh", self.uninstall)
        self.assertIn("rm -f /data/adb/service.d/revanced-zygisk-mount.sh", self.uninstall)

    def test_no_global_mount_is_touched_without_a_zygisk_engine(self):
        # create_procs_map() and disable_revanced_modules() both bail out:
        # without an engine the official global mount must keep working.
        none_guard = 'if [ "$(zygisk_provider)" = "none" ]; then'
        self.assertEqual(self.util.count(none_guard), 2)

    def test_no_engine_warning_tells_the_user_to_reboot_not_reflash(self):
        # The engine is re-detected at every boot, so installing one later
        # must not require re-flashing the module; the warning says so.
        self.assertIn("No need to re-flash this module", self.util)

    def test_long_lines_are_wrapped_for_the_installer_console(self):
        # The console does not wrap by itself: a long line is scrolled
        # sideways. Every installer message goes through rv_print, which
        # breaks it on spaces to a readable width.
        self.assertIn("fold -s -w 52", self.util)
        self.assertIn('rv_print "* Config:', self.util)
        self.assertIn('rv_print "* Module:', self.util)
        self.assertNotIn('ui_print "* Config:', self.util)

    def test_sweep_reads_the_root_field_and_matches_the_module_dir(self):
        # /proc/mounts reports the device of a bind mount, never the source.
        # In mountinfo the root is relative to the source filesystem, so a
        # bind from /data/adb/modules/... is listed as /adb/modules/...
        body = self.util[self.util.index("sweep_revanced_mounts() {"):]
        body = body[:body.index("\n}\n")]
        self.assertIn("done </proc/self/mountinfo", body)
        self.assertIn('*/modules/*/"$_rv_pkg".apk', body)
        self.assertIn('*/modules_update/*/"$_rv_pkg".apk', body)
        self.assertNotIn("/data/adb/modules/*/", body)
        self.assertNotIn('grep -F "$_rv_pkg" /proc/mounts', self.util)
        unmount = body.index('umount -l "$_rv_target"')
        stop = body.index('[ "$_rv_swept" = 1 ] && am force-stop')
        self.assertLess(unmount, stop)

    def test_procs_map_sweeps_before_building_the_map(self):
        body = self.util[self.util.index("create_procs_map() {"):]
        sweep = body.index("sweep_revanced_mounts")
        applied = body.index('rv_print "* Applied for $_rv_pkg"')
        self.assertLess(sweep, applied)

    def test_procs_map_is_renamed_atomically(self):
        self.assertIn('_rv_tmp="$_rv_map.tmp.$$"', self.util)
        self.assertIn('mv -f "$_rv_tmp" "$_rv_map"', self.util)

    def test_service_watches_for_the_delayed_official_mount(self):
        # The official modules mount at boot_completed + ~5s. Watching is
        # bounded: it must not turn the module into a daemon.
        for script in (self.service, self.common_service):
            self.assertIn('while [ "$_rv_i" -lt 15 ]', script)
            self.assertIn("sweep_revanced_mounts", script)
            self.assertNotIn("sleep 15\ncreate_procs_map", script)
        # The Termux helper rebuilds the map on demand and skips the watch.
        self.assertIn('if [ "${1:-}" != "--manual" ]; then', self.common_service)


if __name__ == "__main__":
    unittest.main()
