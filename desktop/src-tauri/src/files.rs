//! Private writes: restrict access before the first content byte, then sync and replace.
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

pub fn protect(path: &Path, directory: bool) -> Result<(), String> {
    let meta = fs::symlink_metadata(path).map_err(|_| "Cannot inspect local storage")?;
    if meta.file_type().is_symlink() || meta.is_dir() != directory {
        return Err("Local storage contains an unexpected link or file".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }),
        )
        .map_err(|_| "Cannot protect local storage")?;
    }
    #[cfg(windows)]
    crate::platform::windows::protect_path(path, directory)?;
    Ok(())
}

pub fn directory(path: &Path) -> Result<(), String> {
    if !path.exists() {
        let parent = path.parent().ok_or("Invalid storage folder")?;
        if !parent.exists() {
            directory(parent)?;
        }
        let builder = fs::DirBuilder::new();
        #[cfg(unix)]
        let builder = {
            use std::os::unix::fs::DirBuilderExt;
            let mut builder = builder;
            builder.mode(0o700);
            builder
        };
        match builder.create(path) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(_) => return Err("Cannot create local storage".into()),
        }
    }
    protect(path, true)
}

pub fn create(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.create_new(true).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(path)
        .map_err(|_| "Cannot create private file")?;
    protect(path, false)?;
    Ok(file)
}

pub fn atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Invalid storage file")?;
    if !parent.exists() {
        directory(parent)?;
    }
    if path.symlink_metadata().is_ok() {
        protect(path, false)?;
    }
    let temporary = parent.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = create(&temporary)?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "Cannot save note")?;
        drop(file);
        // Windows rename cannot replace an existing file. MoveFileExW performs replacement.
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::Foundation::{
                GetLastError, ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION,
            };
            use windows_sys::Win32::Storage::FileSystem::{
                MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
            };
            let from: Vec<u16> = temporary.as_os_str().encode_wide().chain(Some(0)).collect();
            let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            let mut replaced = false;
            for attempt in 0..5 {
                if unsafe {
                    MoveFileExW(
                        from.as_ptr(),
                        to.as_ptr(),
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                    )
                } != 0
                {
                    replaced = true;
                    break;
                }
                let error = unsafe { GetLastError() };
                if !matches!(error, ERROR_SHARING_VIOLATION | ERROR_ACCESS_DENIED) || attempt == 4 {
                    break;
                }
                // Defender and indexing can briefly hold a new file without delete sharing.
                std::thread::sleep(std::time::Duration::from_millis(
                    50 + 25 * attempt.min(2) as u64,
                ));
            }
            if !replaced {
                return Err("Cannot replace saved note".into());
            }
        }
        #[cfg(not(windows))]
        fs::rename(&temporary, path).map_err(|_| "Cannot replace saved note")?;
        #[cfg(unix)]
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|_| "Cannot sync note folder")?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

pub fn notes_root() -> Result<PathBuf, String> {
    #[cfg(windows)]
    let root = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(target_os = "macos")]
    let root =
        std::env::var_os("HOME").map(|p| PathBuf::from(p).join("Library/Application Support"));
    #[cfg(not(any(windows, target_os = "macos")))]
    let root = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".local/share")));
    Ok(root
        .ok_or("Cannot locate local data folder")?
        .join("chirp-desktop")
        .join("notes"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replacement_keeps_private_content_without_changing_export_parent() {
        let parent =
            std::env::temp_dir().join(format!("chirp-files-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&parent).unwrap();
        #[cfg(unix)]
        let mode = {
            use std::os::unix::fs::PermissionsExt;
            fs::metadata(&parent).unwrap().permissions().mode()
        };
        let path = parent.join("export.md");
        atomic(&path, b"synthetic one").unwrap();
        atomic(&path, b"synthetic two").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"synthetic two");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&parent).unwrap().permissions().mode(), mode);
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(parent).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn writes_refuse_symlink_targets() {
        let parent =
            std::env::temp_dir().join(format!("chirp-files-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&parent).unwrap();
        let target = parent.join("target");
        fs::write(&target, b"original").unwrap();
        let link = parent.join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(atomic(&link, b"replacement").is_err());
        assert_eq!(fs::read(target).unwrap(), b"original");
        fs::remove_dir_all(parent).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn replacement_retries_a_transient_delete_sharing_lock() {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::{FILE_SHARE_READ, FILE_SHARE_WRITE};
        let parent =
            std::env::temp_dir().join(format!("chirp-files-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&parent).unwrap();
        let path = parent.join("note.json");
        atomic(&path, b"before").unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .open(&path)
            .unwrap();
        let release = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(150));
            drop(lock);
        });
        atomic(&path, b"after").unwrap();
        release.join().unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"after");
        fs::remove_dir_all(parent).unwrap();
    }
}
