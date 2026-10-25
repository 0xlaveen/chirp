"""Windows DACL access through advapi32 (ctypes, no extra dependency). Imported only on Windows."""

import ctypes
import functools
from ctypes import wintypes

SE_FILE_OBJECT = 1
DACL_SECURITY_INFORMATION = 0x4
PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000
SDDL_REVISION_1 = 1
TOKEN_QUERY = 0x0008
TOKEN_USER = 1

_advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

_kernel32.GetCurrentProcess.restype = wintypes.HANDLE
_kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
_kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
_kernel32.LocalFree.restype = wintypes.HLOCAL
_advapi32.OpenProcessToken.argtypes = [
    wintypes.HANDLE,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.HANDLE),
]
_advapi32.GetTokenInformation.argtypes = [
    wintypes.HANDLE,
    ctypes.c_int,
    ctypes.c_void_p,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
]
_advapi32.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.LPWSTR)]
_advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [
    wintypes.LPCWSTR,
    wintypes.DWORD,
    ctypes.POINTER(ctypes.c_void_p),
    ctypes.POINTER(wintypes.ULONG),
]
_advapi32.GetSecurityDescriptorDacl.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(wintypes.BOOL),
    ctypes.POINTER(ctypes.c_void_p),
    ctypes.POINTER(wintypes.BOOL),
]
_advapi32.SetNamedSecurityInfoW.argtypes = [
    wintypes.LPWSTR,
    ctypes.c_int,
    wintypes.DWORD,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
]
_advapi32.SetNamedSecurityInfoW.restype = wintypes.DWORD
_advapi32.GetNamedSecurityInfoW.argtypes = [
    wintypes.LPCWSTR,
    ctypes.c_int,
    wintypes.DWORD,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
]
_advapi32.GetNamedSecurityInfoW.restype = wintypes.DWORD
_advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW.argtypes = [
    ctypes.c_void_p,
    wintypes.DWORD,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.LPWSTR),
    ctypes.POINTER(wintypes.ULONG),
]


def _check(ok):
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())


@functools.cache
def user_sid() -> str:
    """The current process user's SID, such as S-1-5-21-…-1001."""
    token = wintypes.HANDLE()
    _check(_advapi32.OpenProcessToken(_kernel32.GetCurrentProcess(), TOKEN_QUERY, token))
    try:
        size = wintypes.DWORD()
        _advapi32.GetTokenInformation(token, TOKEN_USER, None, 0, ctypes.byref(size))
        buffer = ctypes.create_string_buffer(size.value)
        _check(_advapi32.GetTokenInformation(token, TOKEN_USER, buffer, size, ctypes.byref(size)))
        # TOKEN_USER starts with SID_AND_ATTRIBUTES, whose first field is the PSID.
        sid = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_void_p))[0]
        text = wintypes.LPWSTR()
        _check(_advapi32.ConvertSidToStringSidW(sid, ctypes.byref(text)))
        try:
            return text.value
        finally:
            _kernel32.LocalFree(ctypes.cast(text, ctypes.c_void_p))
    finally:
        _kernel32.CloseHandle(token)


def set_dacl(path: str, sddl: str) -> None:
    """Replace the DACL of `path` with the one in `sddl`, protected from inheritance."""
    descriptor = ctypes.c_void_p()
    _check(
        _advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl, SDDL_REVISION_1, ctypes.byref(descriptor), None
        )
    )
    try:
        present, defaulted = wintypes.BOOL(), wintypes.BOOL()
        dacl = ctypes.c_void_p()
        _check(
            _advapi32.GetSecurityDescriptorDacl(
                descriptor, ctypes.byref(present), ctypes.byref(dacl), ctypes.byref(defaulted)
            )
        )
        error = _advapi32.SetNamedSecurityInfoW(
            path,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            None,
            None,
            dacl,
            None,
        )
        if error:
            raise ctypes.WinError(error)
    finally:
        _kernel32.LocalFree(descriptor)


def get_dacl(path: str) -> str:
    """The DACL of `path` as SDDL, such as D:P(A;;FA;;;S-1-5-21-…)(A;;FA;;;SY)."""
    dacl, descriptor = ctypes.c_void_p(), ctypes.c_void_p()
    error = _advapi32.GetNamedSecurityInfoW(
        path,
        SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION,
        None,
        None,
        ctypes.byref(dacl),
        None,
        ctypes.byref(descriptor),
    )
    if error:
        raise ctypes.WinError(error)
    try:
        text = wintypes.LPWSTR()
        _check(
            _advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor, SDDL_REVISION_1, DACL_SECURITY_INFORMATION, ctypes.byref(text), None
            )
        )
        try:
            return text.value
        finally:
            _kernel32.LocalFree(ctypes.cast(text, ctypes.c_void_p))
    finally:
        _kernel32.LocalFree(descriptor)
