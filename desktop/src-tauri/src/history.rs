//! Bounded local history. AES-256-GCM ciphertext on disk; key only in the OS credential store.
//! No Debug implementations or transcript-bearing errors.
use aes_gcm::{
    aead::{rand_core::RngCore, Aead, AeadCore, KeyInit, OsRng, Payload},
    Aes256Gcm, Nonce,
};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};

const HEADER: &[u8] = b"CHIRP-HISTORY\x01";
const MAX_ENTRIES: usize = 200;
const MAX_CHARS: usize = 20_000;
const MAX_BYTES: u64 = 40 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    pub time: u64,
    pub text: String,
    pub raw: Option<String>,
}

pub struct Store {
    path: PathBuf,
    _lock: fs::File,
}
impl Store {
    pub fn open(root: PathBuf) -> Result<Self, String> {
        crate::files::directory(&root)?;
        let lock_path = root.join("history.lock");
        let lock = if lock_path.exists() {
            crate::files::protect(&lock_path, false)?;
            fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(lock_path)
                .map_err(|_| "Cannot open history lock")?
        } else {
            crate::files::create(&lock_path)?
        };
        lock.try_lock_exclusive()
            .map_err(|_| "History is open in another Chirp window. Try again.")?;
        Ok(Self {
            path: root.join("history.bin"),
            _lock: lock,
        })
    }
    fn read(&self, key: &[u8; 32]) -> Result<Vec<Entry>, String> {
        if !self.path.exists() {
            return Ok(vec![]);
        }
        crate::files::protect(&self.path, false)?;
        if fs::metadata(&self.path)
            .map_err(|_| "Cannot read history")?
            .len()
            > MAX_BYTES
        {
            return Err("History is too large to open".into());
        }
        let bytes = fs::read(&self.path).map_err(|_| "Cannot read history")?;
        let offset = HEADER.len();
        if bytes.len() < offset + 12 || !bytes.starts_with(HEADER) {
            return Err("History format is unreadable. Delete history to start again.".into());
        }
        let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| "Invalid history key")?;
        let plain = cipher.decrypt(Nonce::from_slice(&bytes[offset..offset + 12]), Payload {
            msg: &bytes[offset + 12..], aad: HEADER,
        }).map_err(|_| "Cannot unlock history. Unlock your system credential store or delete history to start again.")?;
        serde_json::from_slice(&plain).map_err(|_| "History format is unreadable".into())
    }
    fn write(&self, entries: &[Entry], key: &[u8; 32]) -> Result<(), String> {
        let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| "Invalid history key")?;
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let plain = serde_json::to_vec(entries).map_err(|_| "Cannot encode history")?;
        let encrypted = cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: &plain,
                    aad: HEADER,
                },
            )
            .map_err(|_| "Cannot encrypt history")?;
        let mut bytes = HEADER.to_vec();
        bytes.extend_from_slice(&nonce);
        bytes.extend(encrypted);
        crate::files::atomic(&self.path, &bytes).map_err(|_| "Cannot save encrypted history".into())
    }
    fn prune(entries: &mut Vec<Entry>, days: u32, now: u64) {
        let cutoff = now.saturating_sub(u64::from(days) * 86_400_000);
        entries.retain(|entry| entry.time >= cutoff);
        entries.sort_by_key(|entry| entry.time);
        if entries.len() > MAX_ENTRIES {
            entries.drain(..entries.len() - MAX_ENTRIES);
        }
    }
    pub fn entries(&self, key: &[u8; 32], days: u32, now: u64) -> Result<Vec<Entry>, String> {
        let mut entries = self.read(key)?;
        let count = entries.len();
        Self::prune(&mut entries, days, now);
        if count != entries.len() {
            self.write(&entries, key)?;
        }
        entries.reverse();
        Ok(entries)
    }
    pub fn record(
        &self,
        text: String,
        raw: Option<String>,
        key: &[u8; 32],
        days: u32,
        now: u64,
    ) -> Result<(), String> {
        // Keep command-only newlines as delivered, including trailing whitespace.
        if text.is_empty() || text.chars().count() > MAX_CHARS {
            return Ok(());
        }
        let raw = raw.filter(|s| !s.is_empty() && *s != text && s.chars().count() <= MAX_CHARS);
        let mut entries = self.read(key)?;
        entries.push(Entry {
            id: uuid::Uuid::new_v4().to_string(),
            time: now,
            text,
            raw,
        });
        Self::prune(&mut entries, days, now);
        self.write(&entries, key)
    }
    pub fn delete(&self, id: &str, key: &[u8; 32], days: u32) -> Result<(), String> {
        let mut entries = self.entries(key, days, crate::library::now())?;
        entries.retain(|entry| entry.id != id);
        self.write(&entries, key)
    }
    fn key(&self, create: bool) -> Result<Option<[u8; 32]>, String> {
        if !create && !self.path.exists() {
            return Ok(None);
        }
        let entry = keyring::Entry::new("dev.chirp.desktop", "dictation-history-v1")
            .map_err(|_| "System credential store is unavailable")?;
        match entry.get_password() {
            Ok(value) => {
                let bytes = hex::decode(value).map_err(|_| "History key is unreadable")?;
                Ok(Some(bytes.try_into().map_err(|_| "History key is unreadable")?))
            }
            Err(keyring::Error::NoEntry) if !self.path.exists() => {
                if !create { return Ok(None); }
                let mut key = [0u8; 32];
                OsRng.fill_bytes(&mut key);
                entry.set_password(&hex::encode(key)).map_err(|_| "Cannot save history key. Unlock your system credential store.")?;
                Ok(Some(key))
            }
            _ => Err("Cannot unlock history. Unlock your system credential store or delete history to start again.".into()),
        }
    }
    fn clear(&self) -> Result<(), String> {
        if self.path.exists() {
            crate::files::protect(&self.path, false)?;
            fs::remove_file(&self.path).map_err(|_| "Cannot delete history")?;
        }
        let entry = keyring::Entry::new("dev.chirp.desktop", "dictation-history-v1")
            .map_err(|_| "System credential store is unavailable")?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => Err(
                "History was deleted. Unlock your system credential store to remove its key too."
                    .into(),
            ),
        }
    }
}

fn store() -> Result<Store, String> {
    let root = crate::files::notes_root()?
        .parent()
        .ok_or("Cannot locate history folder")?
        .join("history");
    Store::open(root)
}

pub fn record(
    text: String,
    raw: Option<String>,
    settings: &crate::settings::Settings,
) -> Result<(), String> {
    if !settings.history_enabled {
        return Ok(());
    }
    let store = store()?;
    let key = store.key(true)?.ok_or("History key unavailable")?;
    store.record(
        text,
        raw,
        &key,
        settings.history_days,
        crate::library::now(),
    )
}

#[tauri::command]
pub fn history_list(app: tauri::AppHandle) -> Result<Vec<Entry>, String> {
    let settings = app
        .state::<crate::Runtime>()
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let store = store()?;
    match store.key(false)? {
        Some(key) => store.entries(&key, settings.history_days, crate::library::now()),
        None => Ok(vec![]),
    }
}
#[tauri::command]
pub fn history_delete(app: tauri::AppHandle, id: String) -> Result<(), String> {
    let settings = app
        .state::<crate::Runtime>()
        .settings
        .lock()
        .map_err(|_| "Settings unavailable")?
        .clone();
    let store = store()?;
    if let Some(key) = store.key(false)? {
        store.delete(&id, &key, settings.history_days)?;
    }
    Ok(())
}
#[tauri::command]
pub fn history_clear() -> Result<(), String> {
    store()?.clear()
}
#[tauri::command]
pub fn history_copy(app: tauri::AppHandle, id: String, original: bool) -> Result<(), String> {
    let entry = history_list(app)?
        .into_iter()
        .find(|entry| entry.id == id)
        .ok_or("This dictation is no longer in history")?;
    crate::platform::native().copy_text(if original {
        entry.raw.as_deref().unwrap_or(&entry.text)
    } else {
        &entry.text
    })
}
use tauri::Manager;

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (PathBuf, Store) {
        let root =
            std::env::temp_dir().join(format!("chirp-history-test-{}", uuid::Uuid::new_v4()));
        let store = Store::open(root.clone()).unwrap();
        (root, store)
    }
    #[test]
    fn encrypted_roundtrip_search_data_delete_retention_and_lock() {
        let (root, store) = fixture();
        let key = [42; 32];
        let now = 40 * 86_400_000;
        store
            .record(
                "Synthetic polished text\n".into(),
                Some("synthetic original".into()),
                &key,
                7,
                now,
            )
            .unwrap();
        let bytes = fs::read(&store.path).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("Synthetic"));
        let entries = store.entries(&key, 7, now).unwrap();
        assert_eq!(entries[0].text, "Synthetic polished text\n");
        assert_eq!(entries[0].raw.as_deref(), Some("synthetic original"));
        drop(store);
        let store = Store::open(root.clone()).unwrap();
        assert_eq!(
            store.entries(&key, 7, now).unwrap()[0].text,
            "Synthetic polished text\n"
        );
        assert!(Store::open(root.clone()).is_err());
        assert!(store.entries(&[43; 32], 7, now).is_err());
        assert_eq!(
            store.entries(&key, 7, now + 8 * 86_400_000).unwrap().len(),
            0
        );
        for n in 0..205 {
            store.record(n.to_string(), None, &key, 7, now + n).unwrap();
        }
        assert_eq!(store.entries(&key, 7, now + 205).unwrap().len(), 200);
        // Use the real clock so deletion also exercises normal retention pruning.
        store
            .record("Delete me".into(), None, &key, 7, crate::library::now())
            .unwrap();
        let id = store.entries(&key, 7, crate::library::now()).unwrap()[0]
            .id
            .clone();
        store.delete(&id, &key, 7).unwrap();
        assert!(store
            .entries(&key, 7, crate::library::now())
            .unwrap()
            .is_empty());
        drop(store);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn fresh_nonces_tampering_and_no_overwrite_of_unreadable_history() {
        let (root, store) = fixture();
        let key = [7; 32];
        store.write(&[], &key).unwrap();
        let first = fs::read(&store.path).unwrap();
        store.write(&[], &key).unwrap();
        assert_ne!(first, fs::read(&store.path).unwrap());
        let mut damaged = first;
        *damaged.last_mut().unwrap() ^= 1;
        fs::write(&store.path, &damaged).unwrap();
        assert!(store
            .record("Do not overwrite".into(), None, &key, 7, 100)
            .is_err());
        assert_eq!(fs::read(&store.path).unwrap(), damaged);
        drop(store);
        fs::remove_dir_all(root).unwrap();
    }
}
