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

    def test_loaded_native_view_is_required_not_a_filename_exception(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "runtime.json"
            for machine in ("0xAA64", "0x8664", "0xA641"):
                modules = [{"path": "vcruntime140_1.dll", "diskMachine": "0x8664", "mappedMachine": machine}]
                with patch.object(repro, "loaded_modules", return_value=modules):
                    if machine == "0xAA64":
                        repro.runtime_snapshot(path, "before_inverse", [])
                    else:
                        with self.assertRaisesRegex(RuntimeError, "native Arm64 PE view"):
                            repro.runtime_snapshot(path, "before_inverse", [])
                self.assertEqual(json.loads(path.read_text())["snapshots"][0]["modules"], modules)

    def test_success_without_native_dependency_evidence_cannot_pass(self):
        def finish(command, stdout, **_):
            evidence = {"dtype": "complex64", "matrix": "symm", "iterations": 100, "version": "2.3.2"}
            stdout.write("NUMPY_REPRO_OK=" + json.dumps(evidence) + "\n")
            return repro.subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as temp, patch.object(repro.subprocess, "run", side_effect=finish):
            output = Path(temp)
            result = repro.run_case(output, "2.3.2", "complex64", "symm")
            self.assertEqual(result["status"], "unverified_runtime")
            for phases, machine, verified in (
                (["before_inverse"], "0xAA64", False),
                (["before_inverse", "after_inverse"], "0x8664", False),
                (["before_inverse", "after_inverse"], "0xAA64", True),
            ):
                runtime = {"snapshots": [
                    {"phase": phase, "modules": [{"mappedMachine": machine}]} for phase in phases
                ]}
                (output / result["runtimeLog"]).write_text(json.dumps(runtime))
                result = repro.run_case(output, "2.3.2", "complex64", "symm")
                self.assertEqual(result["nativeRuntimeVerified"], verified)
                self.assertEqual(result["status"], "passed" if verified else "unverified_runtime")

    def test_every_packaged_numpy_binary_still_requires_arm64(self):
        with tempfile.TemporaryDirectory() as temp:
            for machine in ("0x8664", "0xA641", "0xA64E"):
                output = Path(temp) / machine
                inventory = [{"scope": "numpy-wheel", "machine": machine, "path": "extension.pyd"}]
                args = ["numpy_reproduction.py", "--version", "2.3.2", "--output", str(output)]
                with patch.object(repro, "native_inventory", return_value=inventory), patch.object(repro.sys, "argv", args):
                    with self.assertRaisesRegex(RuntimeError, "packaged in the NumPy wheel"):
                        repro.main()
                report = json.loads((output / "result.json").read_text())
                self.assertFalse(report["nativeRuntimeVerified"])
                self.assertEqual(report["cases"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
