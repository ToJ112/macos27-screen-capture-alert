"""File-operation tests only; never write a real managed preference or signal replayd."""
import hashlib
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "screen-capture-alert.sh"
KEY = "forceBypassScreenCaptureAlert"


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.target = self.root / "preferences.plist"
        self.state = self.root / "receipt"

    def run_action(self, function, ok=True):
        cmd = "; ".join([
            "source " + shlex.quote(str(SCRIPT)),
            function + " " + shlex.quote(str(self.target)) + " " + shlex.quote(str(self.state)),
        ])
        result = subprocess.run(["/bin/bash", "-c", cmd], capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def write(self, data, binary=False):
        self.target.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML))

    def test_new_file_and_exact_removal_keep_receipt(self):
        self.run_action("install_policy")
        self.assertEqual(plistlib.loads(self.target.read_bytes()), {KEY: True})
        self.assertTrue((self.state / "no-original").is_file())
        self.run_action("uninstall_policy")
        self.assertFalse(self.target.exists())
        self.assertEqual(len(list(self.root.glob("receipt.removed-*"))), 1)

    def test_existing_binary_preserves_other_keys_and_restores_exact_bytes_mode(self):
        self.write({"unrelated": "keep", "array": [1, 2], KEY: False}, binary=True)
        self.target.chmod(0o600)
        original = self.target.read_bytes()
        self.run_action("install_policy")
        changed = plistlib.loads(self.target.read_bytes())
        self.assertEqual(changed, {"unrelated": "keep", "array": [1, 2], KEY: True})
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        self.run_action("uninstall_policy")
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)

    def test_absent_key_in_existing_file(self):
        self.write({"unrelated": 42})
        original = self.target.read_bytes()
        self.run_action("install_policy")
        self.assertEqual(plistlib.loads(self.target.read_bytes()), {"unrelated": 42, KEY: True})
        self.run_action("uninstall_policy")
        self.assertEqual(self.target.read_bytes(), original)

    def test_later_edit_blocks_restore(self):
        self.run_action("install_policy")
        self.write({KEY: True, "later": "must survive"})
        before = hashlib.sha256(self.target.read_bytes()).hexdigest()
        self.run_action("uninstall_policy", ok=False)
        self.assertEqual(hashlib.sha256(self.target.read_bytes()).hexdigest(), before)
        self.assertTrue(self.state.is_dir())

    def test_idempotent_install(self):
        self.run_action("install_policy")
        original = self.target.read_bytes()
        self.run_action("install_policy")
        self.assertEqual(self.target.read_bytes(), original)

    def test_external_true_not_taken_over_or_removed(self):
        self.write({KEY: True, "external": 1})
        original = self.target.read_bytes()
        self.run_action("install_policy")
        self.assertFalse(self.state.exists())
        self.run_action("uninstall_policy", ok=False)
        self.assertEqual(self.target.read_bytes(), original)

    def test_target_symlink_refused(self):
        other = self.root / "other.plist"
        other.write_bytes(plistlib.dumps({"keep": True}))
        self.target.symlink_to(other)
        before = other.read_bytes()
        self.run_action("install_policy", ok=False)
        self.assertEqual(other.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_state_symlink_refused(self):
        other = self.root / "other"
        other.mkdir()
        self.state.symlink_to(other)
        self.run_action("install_policy", ok=False)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(other.iterdir()), [])

    def test_invalid_root_refused_before_backup(self):
        self.write([1, 2])
        self.run_action("install_policy", ok=False)
        self.assertFalse(self.state.exists())

    def test_invalid_plist_refused_before_backup(self):
        self.target.write_text("not a plist")
        self.run_action("install_policy", ok=False)
        self.assertFalse(self.state.exists())

    def test_no_receipt_never_removes_existing_file(self):
        self.write({KEY: True})
        original = self.target.read_bytes()
        self.run_action("uninstall_policy", ok=False)
        self.assertEqual(self.target.read_bytes(), original)

    def test_cli_install_without_admin_refused(self):
        if os.geteuid() == 0:
            self.skipTest("This test must run without root.")
        result = subprocess.run(["/bin/bash", str(SCRIPT), "install", "--allow-untested"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Use sudo", result.stderr)


if __name__ == "__main__":
    unittest.main()
