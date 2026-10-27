//! Windows: a low-level keyboard hook for the single-key hotkey, SendInput (Unicode) to type,
//! and a clipboard paste for long text or when typing is refused. The rules live in
//! `windows_logic` and are tested on every platform; this file is only the Win32 calls.
use super::windows_logic::{self as logic, KeyObserver, Route, Unit};
use super::*;
use std::{
    cell::RefCell,
    mem::{size_of, zeroed},
    ptr::null_mut,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, GlobalFree, HANDLE, HWND, LPARAM, LRESULT, WPARAM},
    Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY},
    System::{
        DataExchange::{
            CloseClipboard, EmptyClipboard, GetClipboardData, IsClipboardFormatAvailable,
            OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
        },
        LibraryLoader::GetModuleHandleW,
        Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE},
        Ole::CF_UNICODETEXT,
        Threading::{
            GetCurrentProcess, GetCurrentThreadId, OpenProcess, OpenProcessToken,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
    },
    UI::{
        Input::KeyboardAndMouse::{
            GetAsyncKeyState, GetKeyboardLayout, MapVirtualKeyExW, SendInput, ToUnicodeEx, INPUT,
            INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
            MAPVK_VK_TO_VSC, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT,
        },
        WindowsAndMessaging::{
            CallNextHookEx, GetForegroundWindow, GetMessageW, GetWindowThreadProcessId,
            PeekMessageW, PostThreadMessageW, SetWindowsHookExW, UnhookWindowsHookEx, HC_ACTION,
            KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, PM_NOREMOVE, WH_KEYBOARD_LL, WM_KEYDOWN, WM_QUIT,
            WM_SYSKEYDOWN, WM_USER,
        },
    },
};

pub struct Windows;

/// Marks Chirp's own SendInput events (also recognisable as injected).
const MARKER: usize = 0x4348_4952; // "CHIR"

struct Hook {
    observer: KeyObserver,
    tx: mpsc::Sender<KeyEvent>,
}

thread_local! {
    // The low-level hook procedure runs on the thread that installed it.
    static HOOK: RefCell<Option<Hook>> = const { RefCell::new(None) };
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let info = &*(lparam as *const KBDLLHOOKSTRUCT);
        let down = matches!(wparam as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
        let injected = info.flags & LLKHF_INJECTED != 0;
        HOOK.with(|cell| {
            let mut cell = cell.borrow_mut();
            let Some(hook) = cell.as_mut() else { return };
            let target = hook.observer.target();
            if down && info.vkCode == target && !injected {
                // The hook can miss releases (lock screen, UAC prompts); re-check before a press.
                if let Some(event) = hook.observer.forget_released(key_down) {
                    let _ = hook.tx.send(event);
                }
            }
            if let Some(event) = hook
                .observer
                .on_key(info.vkCode, info.scanCode, down, injected)
            {
                if event.down && !event.other_key_down && target == logic::VK_RMENU {
                    // Stop a lone Right Alt from opening the focused app's menu bar.
                    send_keys(&[
                        key_input(logic::VK_MENU_MASK, false),
                        key_input(logic::VK_MENU_MASK, true),
                    ]);
                }
                let _ = hook.tx.send(event);
            }
        });
    }
    CallNextHookEx(null_mut(), code, wparam, lparam)
}

fn key_down(vk: u32) -> bool {
    unsafe { GetAsyncKeyState(vk as i32) as u16 & 0x8000 != 0 }
}

fn key_input(vk: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up { KEYEVENTF_KEYUP } else { 0 },
                time: 0,
                dwExtraInfo: MARKER,
            },
        },
    }
}

fn unicode_input(unit: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: 0,
                wScan: unit,
                dwFlags: KEYEVENTF_UNICODE | if up { KEYEVENTF_KEYUP } else { 0 },
                time: 0,
                dwExtraInfo: MARKER,
            },
        },
    }
}

/// Number of events Windows accepted.
fn send_keys(inputs: &[INPUT]) -> usize {
    if inputs.is_empty() {
        return 0;
    }
    unsafe {
        SendInput(
            inputs.len() as u32,
            inputs.as_ptr(),
            size_of::<INPUT>() as i32,
        ) as usize
    }
}

fn foreground() -> (HWND, u32) {
    unsafe {
        let window = GetForegroundWindow();
        let mut process = 0u32;
        let thread = GetWindowThreadProcessId(window, &mut process);
        (window, if thread == 0 { 0 } else { process })
    }
}

fn token_elevated(process: HANDLE) -> Option<bool> {
    unsafe {
        let mut token: HANDLE = null_mut();
        if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 {
            return None;
        }
        let mut elevation: TOKEN_ELEVATION = zeroed();
        let mut size = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            &mut elevation as *mut _ as *mut _,
            size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        );
        CloseHandle(token);
        (ok != 0).then_some(elevation.TokenIsElevated != 0)
    }
}

fn process_elevated(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        // A process we may not even query is more privileged than us.
        if process.is_null() {
            return true;
        }
        let elevated = token_elevated(process).unwrap_or(true);
        CloseHandle(process);
        elevated
    }
}

fn self_elevated() -> bool {
    token_elevated(unsafe { GetCurrentProcess() }).unwrap_or(false)
}

/// Wait (up to a second) for the user to let go of modifiers so typed text never becomes
/// shortcuts such as Ctrl+S.
fn wait_for_modifiers() {
    let deadline = Instant::now() + Duration::from_secs(1);
    while [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN]
        .iter()
        .any(|vk| key_down(*vk as u32))
        && Instant::now() < deadline
    {
        thread::sleep(Duration::from_millis(15));
    }
}

/// Type `units`; returns how many were fully sent before Windows refused one.
fn type_units(units: &[Unit]) -> usize {
    let mut sent = 0;
    for batch in logic::batches(units, 64) {
        let inputs: Vec<INPUT> = batch
            .iter()
            .flat_map(|unit| match *unit {
                Unit::Char(c) => [unicode_input(c, false), unicode_input(c, true)],
                Unit::Key(vk) => [key_input(vk, false), key_input(vk, true)],
            })
            .collect();
        let accepted = send_keys(&inputs);
        if accepted < inputs.len() {
            return sent + accepted / 2;
        }
        sent += batch.len();
        // Let the target drain its input queue between batches.
        thread::sleep(Duration::from_millis(2));
    }
    sent
}

struct Clipboard;
impl Clipboard {
    fn open() -> Result<Self, String> {
        for _ in 0..20 {
            if unsafe { OpenClipboard(null_mut()) } != 0 {
                return Ok(Self);
            }
            thread::sleep(Duration::from_millis(25));
        }
        Err("The clipboard is busy".into())
    }

    fn text(&self) -> Option<Vec<u16>> {
        unsafe {
            if IsClipboardFormatAvailable(CF_UNICODETEXT as u32) == 0 {
                return None;
            }
            let handle = GetClipboardData(CF_UNICODETEXT as u32);
            if handle.is_null() {
                return None;
            }
            let pointer = GlobalLock(handle) as *const u16;
            if pointer.is_null() {
                return None;
            }
            let mut length = 0;
            while *pointer.add(length) != 0 {
                length += 1;
            }
            let text = std::slice::from_raw_parts(pointer, length).to_vec();
            GlobalUnlock(handle);
            Some(text)
        }
    }

    /// Replace the clipboard with `text`, kept out of clipboard history, cloud clipboard and
    /// clipboard monitors.
    fn set(&self, text: &[u16]) -> Result<(), String> {
        unsafe {
            EmptyClipboard();
            put(
                CF_UNICODETEXT as u32,
                text.iter()
                    .copied()
                    .chain([0])
                    .collect::<Vec<u16>>()
                    .as_slice(),
            )?;
            for name in [
                "ExcludeClipboardContentFromMonitorProcessing",
                "CanIncludeInClipboardHistory",
                "CanUploadToCloudClipboard",
            ] {
                let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
                let format = RegisterClipboardFormatW(wide.as_ptr());
                if format != 0 {
                    let _ = put(format, &[0u16, 0u16]);
                }
            }
            Ok(())
        }
    }
}
impl Drop for Clipboard {
    fn drop(&mut self) {
        unsafe {
            CloseClipboard();
        }
    }
}

unsafe fn put(format: u32, data: &[u16]) -> Result<(), String> {
    let bytes = data.len() * 2;
    let memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if memory.is_null() {
        return Err("Out of memory for the clipboard".into());
    }
    let pointer = GlobalLock(memory) as *mut u16;
    if pointer.is_null() {
        GlobalFree(memory);
        return Err("Out of memory for the clipboard".into());
    }
    std::ptr::copy_nonoverlapping(data.as_ptr(), pointer, data.len());
    GlobalUnlock(memory);
    if SetClipboardData(format, memory as HANDLE).is_null() {
        GlobalFree(memory);
        return Err("Could not use the clipboard".into());
    }
    Ok(())
}

fn copy(text: &str) -> Result<(), String> {
    let wide: Vec<u16> = text.encode_utf16().collect();
    Clipboard::open()?.set(&wide)
}

/// Paste `text` with Ctrl+V, then put the user's previous clipboard text back.
fn paste(text: &str) -> Result<(), String> {
    let previous = {
        let clipboard = Clipboard::open()?;
        let previous = clipboard.text();
        clipboard.set(&text.encode_utf16().collect::<Vec<u16>>())?;
        previous
    };
    let ctrl = VK_CONTROL;
    let v = 0x56;
    let sent = send_keys(&[
        key_input(ctrl, false),
        key_input(v, false),
        key_input(v, true),
        key_input(ctrl, true),
    ]);
    // The target reads the clipboard asynchronously after Ctrl+V.
    thread::sleep(Duration::from_millis(250));
    if let (Some(previous), Ok(clipboard)) = (previous, Clipboard::open()) {
        let _ = clipboard.set(&previous);
    }
    if sent == 4 {
        Ok(())
    } else {
        Err("Windows refused the paste".into())
    }
}

fn layout_has_altgr() -> bool {
    unsafe {
        let window = GetForegroundWindow();
        let thread = GetWindowThreadProcessId(window, null_mut());
        let layout = GetKeyboardLayout(thread);
        let mut state = [0u8; 256];
        for vk in [VK_CONTROL, VK_MENU] {
            state[vk as usize] = 0x80;
        }
        state[logic::VK_LCONTROL as usize] = 0x80;
        state[logic::VK_RMENU as usize] = 0x80;
        logic::layout_has_altgr(|vk| {
            let scan = MapVirtualKeyExW(vk, MAPVK_VK_TO_VSC, layout);
            let mut buffer = [0u16; 8];
            // Flag 4: leave the keyboard's dead-key state untouched (Windows 10 1607+).
            ToUnicodeEx(
                vk,
                scan,
                state.as_ptr(),
                buffer.as_mut_ptr(),
                buffer.len() as i32,
                4,
                layout,
            )
        })
    }
}

impl Platform for Windows {
    fn default_hotkey(&self) -> HotKey {
        logic::default_hotkey(layout_has_altgr())
    }

    fn start_hotkey(&self, key: HotKey, tx: Sender<KeyEvent>) -> Result<HotkeyHandle, String> {
        let observer = KeyObserver::new(key)
            .ok_or("Right Option is a Mac key; choose Right Alt or Right Ctrl")?;
        let (ready, started) = mpsc::channel::<Result<u32, String>>();
        thread::Builder::new()
            .name("chirp-hotkey".into())
            .spawn(move || unsafe {
                HOOK.with(|cell| *cell.borrow_mut() = Some(Hook { observer, tx }));
                let hook = SetWindowsHookExW(
                    WH_KEYBOARD_LL,
                    Some(keyboard_hook),
                    GetModuleHandleW(std::ptr::null()),
                    0,
                );
                if hook.is_null() {
                    let _ = ready.send(Err(
                        "Could not watch the keyboard for the dictation key".into()
                    ));
                    return;
                }
                // Create this thread's message queue before anyone posts WM_QUIT to it.
                let mut message: MSG = zeroed();
                PeekMessageW(&mut message, null_mut(), WM_USER, WM_USER, PM_NOREMOVE);
                let _ = ready.send(Ok(GetCurrentThreadId()));
                while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {}
                UnhookWindowsHookEx(hook);
                HOOK.with(|cell| cell.borrow_mut().take());
            })
            .map_err(|_| "Could not start the hotkey thread")?;
        let thread = started.recv().map_err(|_| "The hotkey thread stopped")??;
        Ok(HotkeyHandle::new(move || unsafe {
            PostThreadMessageW(thread, WM_QUIT, 0, 0);
        }))
    }

    fn copy_text(&self, text: &str) -> Result<(), String> {
        copy(text)
    }

    fn insert_text(&self, text: &str) -> Result<InsertionOutcome, String> {
        if text.is_empty() {
            return Ok(InsertionOutcome::Typed);
        }
        if text.len() > 256 * 1024 {
            return Err("Dictation is too long to insert".into());
        }
        let units = logic::units(text);
        let (_, process) = foreground();
        match logic::route(units.len(), process_elevated(process), self_elevated()) {
            Route::CopyOnly => {
                copy(text)?;
                Ok(InsertionOutcome::Clipboard)
            }
            Route::Paste => {
                wait_for_modifiers();
                paste(text)
                    .or_else(|_| copy(text))
                    .map(|_| InsertionOutcome::Typed)
            }
            Route::Type => {
                wait_for_modifiers();
                let sent = type_units(&units);
                if sent == units.len() {
                    return Ok(InsertionOutcome::Typed);
                }
                let rest = logic::remainder(&units[sent..]);
                match paste(&rest) {
                    Ok(()) => Ok(InsertionOutcome::Typed),
                    Err(_) => copy(&rest).map(|_| InsertionOutcome::Clipboard),
                }
            }
        }
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            session: "windows".into(),
            insertion: vec!["sendinput".into(), "clipboard".into()],
            hotkey: true,
            detail: "Text is typed with SendInput; long text is pasted and your clipboard \
                restored. Apps running as administrator get the text on the clipboard to paste."
                .into(),
        }
    }
}

/// Owner-only access for Chirp's private files (notes, transcripts): a protected DACL that
/// allows only the current user and SYSTEM, read back and verified before returning, so callers
/// can fail closed. A directory's entries are inherited by files created inside it. Only the
/// path is passed to Windows; nothing is logged. A path that is already owner-only is left
/// alone: setting a directory's DACL makes Windows walk every file under it.
pub fn protect_path(path: &std::path::Path, directory: bool) -> Result<(), String> {
    let sid = acl::user_sid()?;
    let forms = acl::sid_forms(&sid)?;
    let wide = acl::wide(path.as_os_str());
    if logic::sddl_is_private(&acl::dacl(&wide)?, &forms) {
        return Ok(());
    }
    acl::set_dacl(&wide, &logic::private_sddl(&sid, directory))?;
    let actual = acl::dacl(&wide)?;
    if logic::sddl_is_private(&actual, &forms) {
        Ok(())
    } else {
        Err("Could not restrict access to Chirp's files".into())
    }
}

mod acl {
    use std::{ffi::OsStr, os::windows::ffi::OsStrExt, ptr::null_mut};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, LocalFree, HANDLE},
        Security::{
            Authorization::{
                ConvertSecurityDescriptorToStringSecurityDescriptorW, ConvertSidToStringSidW,
                ConvertStringSecurityDescriptorToSecurityDescriptorW, GetNamedSecurityInfoW,
                SetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT,
            },
            GetSecurityDescriptorDacl, GetTokenInformation, TokenUser, ACL,
            DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
            PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, TOKEN_QUERY, TOKEN_USER,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };

    const FAILED: &str = "Could not restrict access to Chirp's files";

    pub fn wide(text: &OsStr) -> Vec<u16> {
        text.encode_wide().chain([0]).collect()
    }

    unsafe fn take_wide(pointer: *mut u16) -> String {
        let mut length = 0;
        while *pointer.add(length) != 0 {
            length += 1;
        }
        let text = String::from_utf16_lossy(std::slice::from_raw_parts(pointer, length));
        LocalFree(pointer as _);
        text
    }

    /// The current user's SID, such as S-1-5-21-…-1001.
    pub fn user_sid() -> Result<String, String> {
        unsafe {
            let mut token: HANDLE = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err(FAILED.into());
            }
            let mut size = 0u32;
            GetTokenInformation(token, TokenUser, null_mut(), 0, &mut size);
            let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
            let ok =
                GetTokenInformation(token, TokenUser, buffer.as_mut_ptr() as _, size, &mut size);
            CloseHandle(token);
            if ok == 0 {
                return Err(FAILED.into());
            }
            let user = &*(buffer.as_ptr() as *const TOKEN_USER);
            let mut text = null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
                return Err(FAILED.into());
            }
            Ok(take_wide(text))
        }
    }

    /// The SID and the alias SDDL prints it as, if any (LA for the built-in Administrator).
    pub fn sid_forms(sid: &str) -> Result<Vec<String>, String> {
        unsafe {
            let descriptor = descriptor(&format!("O:{sid}"))?;
            let mut text = null_mut();
            let ok = ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor,
                SDDL_REVISION_1,
                OWNER_SECURITY_INFORMATION,
                &mut text,
                null_mut(),
            );
            LocalFree(descriptor as _);
            if ok == 0 {
                return Err(FAILED.into());
            }
            let owner = take_wide(text);
            Ok(vec![
                sid.to_string(),
                owner.trim_start_matches("O:").to_string(),
            ])
        }
    }

    unsafe fn descriptor(sddl: &str) -> Result<PSECURITY_DESCRIPTOR, String> {
        let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
        let text = wide(OsStr::new(sddl));
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            null_mut(),
        ) == 0
        {
            return Err(FAILED.into());
        }
        Ok(descriptor)
    }

    pub fn set_dacl(path: &[u16], sddl: &str) -> Result<(), String> {
        unsafe {
            let descriptor = descriptor(sddl)?;
            let (mut present, mut defaulted) = (0, 0);
            let mut dacl: *mut ACL = null_mut();
            let ok = GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted);
            let error = if ok == 0 {
                1
            } else {
                SetNamedSecurityInfoW(
                    path.as_ptr(),
                    SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                    null_mut(),
                    null_mut(),
                    dacl,
                    null_mut(),
                )
            };
            LocalFree(descriptor as _);
            if error == 0 {
                Ok(())
            } else {
                Err(FAILED.into())
            }
        }
    }

    /// The DACL of `path` as SDDL.
    pub fn dacl(path: &[u16]) -> Result<String, String> {
        unsafe {
            let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
            let error = GetNamedSecurityInfoW(
                path.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                &mut descriptor,
            );
            if error != 0 {
                return Err(FAILED.into());
            }
            let mut text = null_mut();
            let ok = ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor,
                SDDL_REVISION_1,
                DACL_SECURITY_INFORMATION,
                &mut text,
                null_mut(),
            );
            LocalFree(descriptor as _);
            if ok == 0 {
                return Err(FAILED.into());
            }
            Ok(take_wide(text))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protect_path_makes_files_and_directories_owner_only() {
        let root = std::env::temp_dir().join(format!("chirp-acl-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        protect_path(&root, true).unwrap();
        let sid = acl::user_sid().unwrap();
        let forms = acl::sid_forms(&sid).unwrap();
        let wide = |p: &std::path::Path| acl::wide(p.as_os_str());
        assert!(logic::sddl_is_private(
            &acl::dacl(&wide(&root)).unwrap(),
            &forms
        ));
        // A file created inside inherits owner-only access; protecting it explicitly also works.
        let file = root.join("note.md");
        std::fs::write(&file, b"synthetic").unwrap();
        let inherited = acl::dacl(&wide(&file)).unwrap();
        assert!(!inherited.contains(";;;BU)") && !inherited.contains(";;;WD)"));
        protect_path(&file, false).unwrap();
        assert!(logic::sddl_is_private(
            &acl::dacl(&wide(&file)).unwrap(),
            &forms
        ));
        // Already owner-only: a second call leaves the DACL alone and still succeeds.
        let before = acl::dacl(&wide(&root)).unwrap();
        protect_path(&root, true).unwrap();
        assert_eq!(acl::dacl(&wide(&root)).unwrap(), before);
        std::fs::remove_dir_all(&root).unwrap();
    }
}
