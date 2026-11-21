from pathlib import Path
import unittest


SOURCE = (Path(__file__).parents[1] / "zygisk/jni/module.cpp").read_text()


class NativeSafetyTests(unittest.TestCase):
    def test_process_name_is_checked_before_jni_conversion(self):
        guard = "args->nice_name == nullptr"
        conversion = "GetStringUTFChars(args->nice_name"
        self.assertIn(guard, SOURCE)
        self.assertLess(SOURCE.index(guard), SOURCE.index(conversion))

    def test_companion_handoff_rejects_invalid_lengths(self):
        self.assertIn("proc_len == 0 || proc_len > 4096", SOURCE)
        self.assertIn("readFull(fd, proc.data(), proc_len)", SOURCE)

    def test_procs_map_is_read_from_this_module(self):
        self.assertIn("/data/adb/modules/revanced-zygisk-mount/procs_map", SOURCE)

    def test_no_reference_to_the_upstream_module_id(self):
        self.assertNotIn("rvmm-zygisk-mount/procs_map", SOURCE)
        self.assertNotIn("RVMMZygiskMount", SOURCE)

    def test_companion_logs_only_real_problems(self):
        # Missing or empty map is a real error worth a line. A process that
        # is not in the map is not: Zygisk loads us into every app process.
        self.assertIn("procs_map is missing or empty", SOURCE)
        self.assertNotIn("no procs_map entry for", SOURCE)
        self.assertNotIn("invalid or incomplete companion request", SOURCE)

    def test_mount_waits_for_a_private_mount_namespace(self):
        # preAppSpecialize still runs in zygote's mount namespace. Mounting
        # there leaks the bind into every process zygote starts afterwards.
        wait = SOURCE.index("waitForPrivateMountNamespace(pid)")
        setns = SOURCE.index("setns(ns_fd, CLONE_NEWNS)")
        bind = SOURCE.index("mount(src, dst, NULL, MS_BIND, NULL)")
        self.assertLess(wait, setns)
        self.assertLess(setns, bind)
        self.assertIn("ns.st_ino != parent_ns.st_ino", SOURCE)

    def test_bind_cannot_propagate_back_to_other_namespaces(self):
        bind = SOURCE.index("mount(src, dst, NULL, MS_BIND, NULL)")
        slave = SOURCE.index("MS_REC | MS_SLAVE")
        self.assertLess(slave, bind)

    def test_shared_namespace_skips_the_mount_instead_of_leaking_it(self):
        body = SOURCE[SOURCE.index("static bool injectMount"):]
        body = body[:body.index("\n}\n")]
        self.assertIn("never left the zygote mount namespace", body)
        self.assertLess(body.index("never left the zygote"), body.index("MS_BIND"))

    def test_mount_never_lands_in_the_companion_start_namespace(self):
        # The companion starts in the engine daemon's namespace. If setns
        # ever left us there (the app had not unshared yet), a bind there
        # would leak to every process started afterwards: skip instead.
        body = SOURCE[SOURCE.index("static bool injectMount"):]
        body = body[:body.index("\n}\n")]
        start = body.index("struct stat start_ns")
        setns = body.index("setns(ns_fd, CLONE_NEWNS)")
        check = body.index("now_ns.st_dev == start_ns.st_dev")
        bind = body.index("MS_BIND")
        self.assertLess(start, setns)
        self.assertLess(setns, check)
        self.assertLess(check, bind)
        self.assertIn("not mounting", body)


if __name__ == "__main__":
    unittest.main()
