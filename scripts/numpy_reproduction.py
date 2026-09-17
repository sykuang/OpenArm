"""Bounded native-wheel reproduction of numpy/numpy#29442; not a repair."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
from datetime import datetime, timezone
import hashlib
from importlib import metadata
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time

SEED = 1723059677121834
ITERATIONS = 100
DTYPES = ("complex64", "complex128", "float32", "float64")
MATRIX_TYPES = ("symm", "herm")


def pe_machine(path):
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError(f"Invalid DOS header: {path}")
        offset = struct.unpack_from("<I", header, 60)[0]
        if offset < 64 or offset > 65536:
            raise ValueError(f"Invalid PE header offset: {path}")
        stream.seek(offset)
        signature = stream.read(6)
        if len(signature) != 6 or signature[:4] != b"PE\0\0":
            raise ValueError(f"Invalid PE signature: {path}")
        return struct.unpack_from("<H", signature, 4)[0]


def require_native_python():
    if os.name != "nt" or sys.version_info[:3] != (3, 12, 10):
        raise RuntimeError("This fixture requires native Windows Python 3.12.10.")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    kernel.IsWow64Process2.argtypes = (
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)
    )
    process, native = ctypes.c_ushort(), ctypes.c_ushort()
    if not kernel.IsWow64Process2(kernel.GetCurrentProcess(), ctypes.byref(process), ctypes.byref(native)):
        raise ctypes.WinError(ctypes.get_last_error())
    if process.value != 0 or native.value != 0xAA64:
        raise RuntimeError("An actual Arm64 OS and native Python process are mandatory.")
    return kernel


def loaded_modules():
    kernel = require_native_python()
    kernel.K32EnumProcessModules.argtypes = (
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong)
    )
    kernel.K32GetModuleFileNameExW.argtypes = (
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_ulong
    )
    process = kernel.GetCurrentProcess()
    handles = (ctypes.c_void_p * 1024)()
    needed = ctypes.c_ulong()
    if not kernel.K32EnumProcessModules(process, handles, ctypes.sizeof(handles), ctypes.byref(needed)):
        raise ctypes.WinError(ctypes.get_last_error())
    if not needed.value or needed.value > ctypes.sizeof(handles) or needed.value % ctypes.sizeof(ctypes.c_void_p):
        raise RuntimeError("The loaded-module inventory is empty, invalid or exceeds 1024 modules.")
    modules = []
    for base in handles[:needed.value // ctypes.sizeof(ctypes.c_void_p)]:
        if not base:
            raise RuntimeError("A loaded module has no image base.")
        name = ctypes.create_unicode_buffer(32768)
        length = kernel.K32GetModuleFileNameExW(process, base, name, len(name))
        if not length or length >= len(name):
            raise RuntimeError("Cannot identify a loaded runtime module.")
        header = ctypes.string_at(base, 64)
        offset = struct.unpack_from("<I", header, 60)[0]
        if header[:2] != b"MZ" or offset < 64 or offset > 65536:
            raise RuntimeError("A loaded module has an invalid PE header.")
        signature = ctypes.string_at(base + offset, 6)
        if signature[:4] != b"PE\0\0":
            raise RuntimeError("A loaded module has an invalid PE signature.")
        path = Path(name.value)
        modules.append({
            "path": str(path), "diskMachine": f"0x{pe_machine(path):04X}",
            "mappedMachine": f"0x{struct.unpack_from('<H', signature, 4)[0]:04X}",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    return modules


def runtime_snapshot(output, phase, snapshots):
    modules = loaded_modules()
    snapshots.append({"phase": phase, "modules": modules})
    output.write_text(json.dumps({"snapshots": snapshots}, indent=2) + "\n", encoding="utf-8")
    if any(item["mappedMachine"] != "0xAA64" for item in modules):
        raise RuntimeError("Every loaded module must expose a native Arm64 PE view, including platform runtime DLLs.")


def native_inventory(version):
    require_native_python()
    distribution = metadata.distribution("numpy")
    if distribution.version != version or not distribution.files:
        raise RuntimeError("The installed NumPy distribution does not match the declared fixture.")
    prefix = Path(sys.base_prefix).resolve()
    wheel_paths = {Path(distribution.locate_file(item)).resolve() for item in distribution.files}
    paths = {Path(sys.executable).resolve(), *prefix.glob("*.exe"), *prefix.glob("*.dll"),
             *prefix.joinpath("DLLs").rglob("*"), *wheel_paths}
    binaries = []
    for path in sorted(paths):
        if not path.is_file() or path.suffix.lower() not in (".exe", ".dll", ".pyd"):
            continue
        machine = pe_machine(path)
        binaries.append({
            "path": str(path), "machine": f"0x{machine:04X}",
            "scope": "numpy-wheel" if path in wheel_paths else "python-installation",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    if not any(item["scope"] == "numpy-wheel" and Path(item["path"]).suffix.lower() == ".pyd" for item in binaries):
        raise RuntimeError("No installed native extension binaries were inventoried.")
    return binaries


def exercise(dtype_name, matrix_type, version, runtime_output):
    require_native_python()
    import numpy as np

    if np.__version__ != version:
        raise RuntimeError("The child process imported an unexpected NumPy version.")
    print(f"Python {sys.version}; NumPy {np.__version__}; seed {SEED}", flush=True)
    np.show_config()
    dtype = np.dtype(dtype_name)
    snapshots = []
    runtime_snapshot(runtime_output, "before_inverse", snapshots)
    try:
        for _ in range(ITERATIONS):
            rng = np.random.default_rng(SEED)
            matrix = rng.random((20, 20)) + rng.random((20, 20)) * 1j
            if np.issubdtype(dtype, np.floating):
                matrix = matrix.real
            matrix = matrix.astype(dtype)
            matrix = matrix + matrix.T if matrix_type == "symm" else matrix + matrix.conj().T
            inverse = np.linalg.inv(matrix)
            tolerance = 1e-3 if dtype_name in ("float32", "complex64") else 1e-10
            np.testing.assert_allclose(matrix @ inverse, np.eye(20), rtol=tolerance, atol=tolerance)
    finally:
        runtime_snapshot(runtime_output, "after_inverse", snapshots)
    print("NUMPY_REPRO_OK=" + json.dumps({
        "dtype": dtype_name, "matrix": matrix_type, "iterations": ITERATIONS, "version": version
    }), flush=True)


def case_status(returncode, log, dtype, matrix, version):
    if returncode & 0xFFFFFFFF == 0xC0000005:
        return "access_violation"
    if returncode != 0:
        return "failed"
    expected = {"dtype": dtype, "matrix": matrix, "iterations": ITERATIONS, "version": version}
    lines = log.splitlines()
    if not lines or not lines[-1].startswith("NUMPY_REPRO_OK="):
        return "missing_completion"
    try:
        actual = json.loads(lines[-1].removeprefix("NUMPY_REPRO_OK="))
    except json.JSONDecodeError:
        return "invalid_completion"
    return "passed" if actual == expected else "invalid_completion"


def run_case(output, version, dtype, matrix):
    log_path = output / f"{dtype}-{matrix}.log"
    runtime_path = output / f"{dtype}-{matrix}-runtime.json"
    started = time.perf_counter()
    result = {"dtype": dtype, "matrix": matrix, "log": log_path.name, "exitCode": None,
              "runtimeLog": runtime_path.name, "nativeRuntimeVerified": False}
    with log_path.open("w", encoding="utf-8") as log:
        try:
            process = subprocess.run(
                [sys.executable, "-I", "-X", "faulthandler", str(Path(__file__).resolve()),
                 "--version", version, "--case", dtype, matrix, "--runtime-output", str(runtime_path)],
                stdout=log, stderr=subprocess.STDOUT, timeout=120, check=False,
            )
            result["exitCode"] = process.returncode
        except subprocess.TimeoutExpired:
            result["status"] = "timeout"
    if "status" not in result:
        result["status"] = case_status(
            result["exitCode"], log_path.read_text(encoding="utf-8", errors="replace"),
            dtype, matrix, version,
        )
    if runtime_path.is_file():
        runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
        phases = [item["phase"] for item in runtime["snapshots"]]
        expected = ["before_inverse", "after_inverse"] if result["status"] == "passed" else ["before_inverse"]
        result["nativeRuntimeVerified"] = (
            phases in (expected, ["before_inverse", "after_inverse"])
            and all(snapshot["modules"] and all(item["mappedMachine"] == "0xAA64" for item in snapshot["modules"])
                    for snapshot in runtime["snapshots"])
        )
    if result["status"] == "passed" and not result["nativeRuntimeVerified"]:
        result["status"] = "unverified_runtime"
    result["elapsedMs"] = round((time.perf_counter() - started) * 1000, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=("2.3.2", "2.5.3"), required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--case", nargs=2, metavar=("DTYPE", "MATRIX"))
    parser.add_argument("--runtime-output", type=Path)
    args = parser.parse_args()
    if args.case:
        if args.output or not args.runtime_output or args.case[0] not in DTYPES or args.case[1] not in MATRIX_TYPES:
            parser.error("Use one reviewed dtype/matrix pair with --runtime-output and without --output.")
        exercise(*args.case, args.version, args.runtime_output)
        return 0
    if args.runtime_output:
        parser.error("--runtime-output is only valid for a child case.")
    if not args.output:
        parser.error("--output is required for a full native reproduction.")
    args.output.mkdir(parents=True, exist_ok=False)
    report = {
        "schemaVersion": 1, "purpose": "Native wheel reproduction, not agent repair or source validation",
        "issue": "https://github.com/numpy/numpy/issues/29442", "numpyVersion": args.version,
        "workflowCommit": os.environ.get("GITHUB_SHA"), "workflowRunId": os.environ.get("GITHUB_RUN_ID"),
        "harnessSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "pythonVersion": sys.version, "seed": SEED, "iterationsPerCase": ITERATIONS, "workers": 2,
        "startedAt": datetime.now(timezone.utc).isoformat(), "status": "assessing",
        "nativeRuntimeVerified": False, "reproducedAccessViolation": False, "binaries": [], "cases": [],
    }
    try:
        report["binaries"] = native_inventory(args.version)
        if any(item["machine"] != "0xAA64" for item in report["binaries"] if item["scope"] == "numpy-wheel"):
            raise RuntimeError("Every binary packaged in the NumPy wheel must be native PE 0xAA64.")
        if pe_machine(Path(sys.executable)) != 0xAA64:
            raise RuntimeError("The executing Python interpreter must be native PE 0xAA64.")
        with ThreadPoolExecutor(max_workers=2) as workers:
            futures = [
                workers.submit(run_case, args.output, args.version, dtype, matrix)
                for dtype in DTYPES for matrix in MATRIX_TYPES
            ]
            report["cases"] = [future.result() for future in futures]
        report["nativeRuntimeVerified"] = all(item["nativeRuntimeVerified"] for item in report["cases"])
        report["reproducedAccessViolation"] = any(
            item["status"] == "access_violation" and item["nativeRuntimeVerified"] for item in report["cases"]
        )
        report["status"] = "passed" if all(item["status"] == "passed" for item in report["cases"]) else "failed"
    except Exception as error:
        report["status"] = "error"
        report["error"] = str(error)
        raise
    finally:
        report["completedAt"] = datetime.now(timezone.utc).isoformat()
        (args.output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("status", "nativeRuntimeVerified", "reproducedAccessViolation", "cases")}))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
