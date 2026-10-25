"""Run each server test file in its own Windows Job Object (CI diagnostics).

A Job Object holds the file's pytest process and every descendant, including the real
interpreters that a venv's python.exe launcher starts, which survive killing the launcher. The
job caps processes and memory and is killed on close, so a runaway test cannot exhaust the
runner. Each file reports its exit code, time, processes started and peak memory; a failing file
prints its whole output. Usage: python scripts/windows_test_driver.py [pytest options]
"""

import ctypes
import glob
import subprocess
import sys
import tempfile
import time
from ctypes import wintypes

TIMEOUT = 150
MAX_PROCESSES = 64
MAX_MEMORY = 6 * 1024**3

JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x8
JOB_OBJECT_LIMIT_JOB_MEMORY = 0x200
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
BASIC_ACCOUNTING, EXTENDED_LIMITS = 1, 9


class BasicLimits(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64),
        ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", wintypes.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wintypes.DWORD),
        ("SchedulingClass", wintypes.DWORD),
    ]


class ExtendedLimits(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", BasicLimits),
        ("IoInfo", ctypes.c_uint64 * 6),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class Accounting(ctypes.Structure):
    _fields_ = [
        ("TotalUserTime", ctypes.c_int64),
        ("TotalKernelTime", ctypes.c_int64),
        ("ThisPeriodTotalUserTime", ctypes.c_int64),
        ("ThisPeriodTotalKernelTime", ctypes.c_int64),
        ("TotalPageFaultCount", wintypes.DWORD),
        ("TotalProcesses", wintypes.DWORD),
        ("ActiveProcesses", wintypes.DWORD),
        ("TotalTerminatedProcesses", wintypes.DWORD),
    ]


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateJobObjectW.restype = wintypes.HANDLE
kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
kernel32.SetInformationJobObject.argtypes = [
    wintypes.HANDLE,
    ctypes.c_int,
    ctypes.c_void_p,
    wintypes.DWORD,
]
kernel32.QueryInformationJobObject.argtypes = [
    wintypes.HANDLE,
    ctypes.c_int,
    ctypes.c_void_p,
    wintypes.DWORD,
    ctypes.c_void_p,
]
kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
kernel32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
# Start suspended, join the job, then resume: a venv's python.exe launcher starts the real
# interpreter at once, and a child started before the assignment would escape the job.
CREATE_SUSPENDED = 0x4
ntdll = ctypes.WinDLL("ntdll")
ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]


def new_job():
    job = kernel32.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    limits = ExtendedLimits()
    limits.BasicLimitInformation.LimitFlags = (
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS
        | JOB_OBJECT_LIMIT_JOB_MEMORY
        | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    )
    limits.BasicLimitInformation.ActiveProcessLimit = MAX_PROCESSES
    limits.JobMemoryLimit = MAX_MEMORY
    if not kernel32.SetInformationJobObject(
        job, EXTENDED_LIMITS, ctypes.byref(limits), ctypes.sizeof(limits)
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return job


def usage(job):
    accounting, limits = Accounting(), ExtendedLimits()
    kernel32.QueryInformationJobObject(
        job, BASIC_ACCOUNTING, ctypes.byref(accounting), ctypes.sizeof(accounting), None
    )
    kernel32.QueryInformationJobObject(
        job, EXTENDED_LIMITS, ctypes.byref(limits), ctypes.sizeof(limits), None
    )
    return (
        f"processes={accounting.TotalProcesses} still_running={accounting.ActiveProcesses} "
        f"peak_memory={limits.PeakJobMemoryUsed // 2**20}MB"
    )


def main():
    failed = []
    for name in sorted(glob.glob("tests/test_*.py")):
        job = new_job()
        with tempfile.TemporaryFile() as out:
            started = time.monotonic()
            process = subprocess.Popen(
                [sys.executable, "-m", "pytest", *sys.argv[1:], name],
                stdout=out,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                creationflags=CREATE_SUSPENDED,
            )
            if not kernel32.AssignProcessToJobObject(job, int(process._handle)):
                raise ctypes.WinError(ctypes.get_last_error())
            ntdll.NtResumeProcess(int(process._handle))
            try:
                code = process.wait(TIMEOUT)
            except subprocess.TimeoutExpired:
                code = "timeout"
            report = usage(job)
            kernel32.TerminateJobObject(job, 1)
            kernel32.CloseHandle(job)
            out.seek(0)
            text = out.read().decode(errors="replace")
        elapsed = time.monotonic() - started
        print(f"::group::{name} -> {code} in {elapsed:.0f}s {report}", flush=True)
        print(text if code not in (0, 5) else text[-1500:], flush=True)
        print("::endgroup::", flush=True)
        if code not in (0, 5):
            failed.append(f"{name}: {code} ({report})")
    print("\n".join(failed) or "all files passed", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
