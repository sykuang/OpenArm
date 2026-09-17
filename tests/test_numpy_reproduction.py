"""Offline harness contracts; these do not establish native NumPy behavior."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("numpy_reproduction", ROOT / "scripts" / "numpy_reproduction.py")
repro = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repro)


class ReproductionChecks(unittest.TestCase):
    def test_real_crash_exit_codes_are_not_other_failures(self):
        for code in (3221225477, -1073741819):
            self.assertEqual(repro.case_status(code, "", "complex64", "symm", "2.3.2"), "access_violation")
        self.assertEqual(repro.case_status(1, "", "complex64", "symm", "2.3.2"), "failed")

    def test_success_requires_exact_exercised_fixture(self):
        evidence = {"dtype": "complex64", "matrix": "symm", "iterations": 100, "version": "2.3.2"}
        log = "NUMPY_REPRO_OK=" + json.dumps(evidence)
        self.assertEqual(repro.case_status(0, log, "complex64", "symm", "2.3.2"), "passed")
        for key, value in (("dtype", "float32"), ("matrix", "herm"), ("iterations", 0), ("version", "2.5.3")):
            wrong = "NUMPY_REPRO_OK=" + json.dumps({**evidence, key: value})
            self.assertEqual(repro.case_status(0, wrong, "complex64", "symm", "2.3.2"), "invalid_completion")
        self.assertEqual(repro.case_status(0, "version only", "complex64", "symm", "2.3.2"), "missing_completion")
        self.assertEqual(repro.case_status(0, "NUMPY_REPRO_OK={", "complex64", "symm", "2.3.2"), "invalid_completion")

    def test_pe_machine_is_from_headers_not_names(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "arm64.dll"
            content = bytearray(256)
            content[:2] = b"MZ"
            struct.pack_into("<I", content, 60, 128)
            content[128:132] = b"PE\0\0"
            for machine in (0xAA64, 0x8664, 0xA641):
                struct.pack_into("<H", content, 132, machine)
                path.write_bytes(content)
                self.assertEqual(repro.pe_machine(path), machine)
            for invalid in (b"", b"MZ", bytes(256)):
                path.write_bytes(invalid)
                with self.assertRaises(ValueError):
                    repro.pe_machine(path)

    def test_non_windows_never_qualifies_as_native(self):
        with patch.object(repro.os, "name", "posix"):
            with self.assertRaisesRegex(RuntimeError, "native Windows"):
                repro.native_inventory("2.3.2")

    def test_case_timeout_stays_failure_with_a_log(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(repro.subprocess, "run", side_effect=repro.subprocess.TimeoutExpired("python", 120)):
                result = repro.run_case(Path(temp), "2.3.2", "complex64", "symm")
            self.assertEqual(result["status"], "timeout")
            self.assertIsNone(result["exitCode"])
            self.assertTrue((Path(temp) / result["log"]).is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
