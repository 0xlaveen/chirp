//! Local document library. Records are authoritative; the small index is rebuildable.
use crate::files;
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_RECORD: u64 = 16 * 1024 * 1024;
const TRASH_MS: u64 = 30 * 24 * 60 * 60 * 1000;
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn valid_id(id: &str) -> Result<(), String> {
    uuid::Uuid::parse_str(id)
        .ok()
        .filter(|v| v.to_string() == id)
        .map(|_| ())
        .ok_or_else(|| "Invalid note identifier".into())
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Segment {
    pub id: String,
    pub text: String,
    pub start_ms: u64,
    pub duration_ms: u64,
    #[serde(default)]
    pub notes_state: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Boundary {
    pub at_ms: u64,
    pub created_at: u64,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Note {
    pub schema: u32,
    pub id: String,
    pub title: String,
    pub renamed: bool,
    pub created_at: u64,
    pub updated_at: u64,
    pub deleted_at: Option<u64>,
    pub body: String,
    pub body_version: u64,
    pub segments: Vec<Segment>,
    pub boundaries: Vec<Boundary>,
    pub duration_ms: u64,
    pub recording: bool,
    pub paused: bool,
    pub recovered: bool,
    pub last_error: String,
    pub organize_undo: Option<String>,
}
impl Note {
    fn blank(&self) -> bool {
        self.body.trim().is_empty() && self.segments.is_empty() && !self.renamed
    }
    fn infer_title(&mut self) {
        if self.renamed {
            return;
        }
        let heading = self
            .body
            .lines()
            .find(|line| line.starts_with('#') && !line.trim_start_matches('#').trim().is_empty());
        let first = heading
            .or_else(|| self.body.lines().find(|l| !l.trim().is_empty()))
            .or_else(|| self.segments.first().map(|s| s.text.as_str()));
        self.title = first
            .map(|line| {
                line.trim()
                    .trim_start_matches(['#', '-', '*', ' '])
                    .chars()
                    .take(100)
                    .collect()
            })
            .filter(|s: &String| !s.is_empty())
            .unwrap_or_else(|| {
                time::OffsetDateTime::from_unix_timestamp((self.created_at / 1000) as i64)
                    .map(|date| format!("Note, {} {}", date.day(), date.month()))
                    .unwrap_or_else(|_| "Untitled note".into())
            });
    }
    pub fn markdown(&self) -> String {
        let mut value = format!("# {}\n\n{}\n", self.title, self.body);
        if !self.segments.is_empty() {
            value.push_str("\n---\n\n## Transcript\n");
            for s in &self.segments {
                value.push_str(&format!(
                    "\n[{:02}:{:02}] {}\n",
                    s.start_ms / 60000,
                    s.start_ms / 1000 % 60,
                    s.text
                ));
            }
        }
        value
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    pub title: String,
    pub snippet: String,
    pub todos: usize,
    pub created_at: u64,
    pub updated_at: u64,
    pub deleted_at: Option<u64>,
    pub duration_ms: u64,
    pub recording: bool,
    pub paused: bool,
    pub recovered: bool,
}
impl From<&Note> for Entry {
    fn from(n: &Note) -> Self {
        Self {
            id: n.id.clone(),
            title: n.title.clone(),
            snippet: n.body.chars().take(160).collect(),
            todos: n
                .body
                .lines()
                .filter(|l| l.trim_start().starts_with("- [ ]"))
                .count(),
            created_at: n.created_at,
            updated_at: n.updated_at,
            deleted_at: n.deleted_at,
            duration_ms: n.duration_ms,
            recording: n.recording,
            paused: n.paused,
            recovered: n.recovered,
        }
    }
}
#[derive(Serialize, Deserialize)]
struct Index {
    schema: u32,
    entries: BTreeMap<String, Entry>,
}

pub struct Library {
    root: PathBuf,
    _lock: File,
    index: BTreeMap<String, Entry>,
    // Only append-only AI changes can merge into an older editor snapshot.
    appends: BTreeMap<String, Vec<(u64, String)>>,
    pub warnings: usize,
}
impl Library {
    pub fn open(root: &Path) -> Result<Self, String> {
        files::directory(root)?;
        let lock_path = root.join(".lock");
        let lock = match files::create(&lock_path) {
            Ok(f) => f,
            Err(_) => {
                files::protect(&lock_path, false)?;
                std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&lock_path)
                    .map_err(|_| "Cannot open notes lock")?
            }
        };
        lock.try_lock_exclusive()
            .map_err(|_| "Notes are open in another Chirp process")?;
        let index = fs::read(root.join("index.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Index>(&b).ok())
            .filter(|i| i.schema == 1)
            .map(|i| i.entries)
            .unwrap_or_default();
        let mut library = Self {
            root: root.into(),
            _lock: lock,
            index,
            appends: BTreeMap::new(),
            warnings: 0,
        };
        // Find unindexed records (including a crash between record and index replacement).
        let paths = fs::read_dir(root).map_err(|_| "Cannot read notes folder")?;
        let mut found = std::collections::BTreeSet::new();
        for path in paths.flatten().map(|v| v.path()) {
            let Some(id) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if path.extension().and_then(|s| s.to_str()) != Some("json") || valid_id(id).is_err() {
                continue;
            }
            found.insert(id.to_owned());
            // Recovery also reads each record's header: index may be older than its record.
            match library.get(id) {
                Ok(mut note) => {
                    if note.recording || note.paused {
                        note.recording = false;
                        note.paused = false;
                        note.recovered = true;
                        note.last_error =
                            "Recording interrupted. Completed segments were recovered.".into();
                        library.save(&mut note)?;
                    } else {
                        library.index.insert(id.into(), Entry::from(&note));
                    }
                    if note.blank() && !note.recording && !note.paused {
                        library.discard_blank(id)?;
                        continue;
                    }
                    let pending: Vec<_> = note
                        .segments
                        .iter()
                        .filter(|s| s.notes_state == "pending")
                        .map(|s| (s.id.clone(), s.text.clone()))
                        .collect();
                    for (sid, text) in pending {
                        library.append_notes(id, &sid, &text, false)?;
                    }
                }
                Err(_) => {
                    library.warnings += 1;
                    library.index.remove(id);
                }
            }
        }
        library.index.retain(|id, _| found.contains(id));
        library.purge_at(now())?;
        library.write_index()?;
        Ok(library)
    }
    fn path(&self, id: &str) -> Result<PathBuf, String> {
        valid_id(id)?;
        Ok(self.root.join(format!("{id}.json")))
    }
    fn write_index(&self) -> Result<(), String> {
        files::atomic(
            &self.root.join("index.json"),
            &serde_json::to_vec(&Index {
                schema: 1,
                entries: self.index.clone(),
            })
            .map_err(|_| "Cannot encode notes index")?,
        )
    }
    pub fn get(&self, id: &str) -> Result<Note, String> {
        let path = self.path(id)?;
        files::protect(&path, false)?;
        if fs::metadata(&path)
            .map_err(|_| "Cannot inspect note")?
            .len()
            > MAX_RECORD
        {
            return Err("Note exceeds the supported size".into());
        }
        let note: Note = serde_json::from_slice(&fs::read(path).map_err(|_| "Cannot read note")?)
            .map_err(|_| "Note is unreadable; its file has been kept")?;
        if note.schema != 1 || note.id != id {
            return Err("This note needs a newer Chirp version; its file has been kept".into());
        }
        Ok(note)
    }
    fn save(&mut self, n: &mut Note) -> Result<(), String> {
        n.infer_title();
        n.updated_at = now();
        let bytes = serde_json::to_vec(n).map_err(|_| "Cannot encode note")?;
        if bytes.len() as u64 > MAX_RECORD {
            return Err("Note is full. Start another note.".into());
        }
        files::atomic(&self.path(&n.id)?, &bytes)?;
        self.index.insert(n.id.clone(), Entry::from(&*n));
        self.write_index()
    }
    pub fn create(&mut self) -> Result<Note, String> {
        let at = now();
        let mut n = Note {
            schema: 1,
            id: uuid::Uuid::new_v4().to_string(),
            title: String::new(),
            renamed: false,
            created_at: at,
            updated_at: at,
            deleted_at: None,
            body: String::new(),
            body_version: 0,
            segments: vec![],
            boundaries: vec![],
            duration_ms: 0,
            recording: false,
            paused: false,
            recovered: false,
            last_error: String::new(),
            organize_undo: None,
        };
        self.save(&mut n)?;
        Ok(n)
    }
    pub fn list(&self, query: &str, trash: bool) -> Vec<Entry> {
        let query = query.to_lowercase();
        let mut entries: Vec<_> = self
            .index
            .values()
            .filter(|e| e.deleted_at.is_some() == trash)
            .filter(|e| {
                query.is_empty()
                    || e.title.to_lowercase().contains(&query)
                    || e.snippet.to_lowercase().contains(&query)
                    || self.get(&e.id).is_ok_and(|n| {
                        n.body.to_lowercase().contains(&query)
                            || n.segments
                                .iter()
                                .any(|s| s.text.to_lowercase().contains(&query))
                    })
            })
            .cloned()
            .collect();
        entries.sort_by_key(|e| {
            (
                std::cmp::Reverse(e.recording),
                std::cmp::Reverse(e.updated_at),
            )
        });
        entries
    }
    pub fn edit(
        &mut self,
        id: &str,
        expected: u64,
        body: String,
        title: Option<String>,
    ) -> Result<Note, String> {
        let mut n = self.get(id)?;
        if n.deleted_at.is_some() {
            return Err("Restore this note before editing".into());
        }
        if body.len() > 4 * 1024 * 1024 {
            return Err("Note text is too large".into());
        }
        let suffix = if expected == n.body_version {
            String::new()
        } else {
            let changes=self.appends.get(id).ok_or("Note changed elsewhere. Your text is still in the editor; reload after copying it.")?;
            let selected: Vec<_> = changes
                .iter()
                .filter(|(version, _)| *version > expected)
                .collect();
            if expected > n.body_version
                || selected.len() as u64 != n.body_version - expected
                || selected.first().is_none_or(|(v, _)| *v != expected + 1)
            {
                return Err("Note changed elsewhere. Copy your text before reloading.".into());
            }
            selected.iter().map(|(_, s)| s.as_str()).collect::<String>()
        };
        n.body = if !body.is_empty() && !suffix.is_empty() && !suffix.starts_with('\n') {
            format!("{body}\n\n{suffix}")
        } else {
            body + &suffix
        };
        n.body_version += 1;
        n.organize_undo = None;
        self.appends.remove(id);
        if let Some(title) = title {
            let title = title.trim();
            if title.chars().count() > 160 {
                return Err("Use a shorter title".into());
            }
            n.renamed = !title.is_empty();
            n.title = title.into();
        }
        self.save(&mut n)?;
        Ok(n)
    }
    pub fn set_recording(
        &mut self,
        id: &str,
        recording: bool,
        paused: bool,
        continued: bool,
        error: &str,
    ) -> Result<Note, String> {
        let mut n = self.get(id)?;
        if n.deleted_at.is_some() {
            return Err("Restore this note before recording".into());
        }
        if continued && !n.segments.is_empty() && !n.paused {
            n.boundaries.push(Boundary {
                at_ms: n.duration_ms,
                created_at: now(),
            });
        }
        n.recording = recording;
        n.paused = paused;
        n.recovered = false;
        n.last_error = error.into();
        self.save(&mut n)?;
        Ok(n)
    }
    pub fn segment(
        &mut self,
        id: &str,
        text: String,
        duration_ms: u64,
    ) -> Result<(Note, String), String> {
        let mut n = self.get(id)?;
        let sid = uuid::Uuid::new_v4().to_string();
        n.segments.push(Segment {
            id: sid.clone(),
            text,
            start_ms: n.duration_ms,
            duration_ms,
            notes_state: "pending".into(),
        });
        n.duration_ms += duration_ms;
        self.save(&mut n)?;
        Ok((n, sid))
    }
    pub fn append_notes(
        &mut self,
        id: &str,
        segment: &str,
        markdown: &str,
        structured: bool,
    ) -> Result<Note, String> {
        let mut n = self.get(id)?;
        if n.deleted_at.is_some() {
            return Ok(n);
        }
        let s = n
            .segments
            .iter_mut()
            .find(|s| s.id == segment)
            .ok_or("Segment no longer exists")?;
        if s.notes_state != "pending" {
            return Ok(n);
        }
        s.notes_state = if structured {
            "structured"
        } else {
            "transcript"
        }
        .into();
        let suffix = format!(
            "{}{}",
            if n.body.is_empty() { "" } else { "\n\n" },
            markdown.trim()
        );
        n.body.push_str(&suffix);
        n.body_version += 1;
        n.organize_undo = None;
        let changes = self.appends.entry(id.into()).or_default();
        changes.push((n.body_version, suffix));
        if changes.len() > 32 {
            changes.remove(0);
        }
        self.save(&mut n)?;
        Ok(n)
    }
    pub fn organize(&mut self, id: &str, expected: u64, markdown: String) -> Result<Note, String> {
        let mut n = self.get(id)?;
        if n.deleted_at.is_some() || n.body_version != expected || n.recording || n.paused {
            return Err("Note changed while organizing. Your edits were kept.".into());
        }
        n.organize_undo = Some(std::mem::replace(&mut n.body, markdown));
        n.body_version += 1;
        self.appends.remove(id);
        self.save(&mut n)?;
        Ok(n)
    }
    pub fn undo_organize(&mut self, id: &str) -> Result<Note, String> {
        let mut n = self.get(id)?;
        n.body = n.organize_undo.take().ok_or("No organization to undo")?;
        n.body_version += 1;
        self.appends.remove(id);
        self.save(&mut n)?;
        Ok(n)
    }
    pub fn trash(&mut self, id: &str, deleted: bool) -> Result<(), String> {
        let mut n = self.get(id)?;
        if n.recording || n.paused {
            return Err("Stop this note before deleting it".into());
        }
        n.deleted_at = deleted.then(now);
        self.save(&mut n)?;
        if !deleted {
            let pending: Vec<_> = n
                .segments
                .iter()
                .filter(|s| s.notes_state == "pending")
                .map(|s| (s.id.clone(), s.text.clone()))
                .collect();
            for (sid, text) in pending {
                self.append_notes(id, &sid, &text, false)?;
            }
        }
        Ok(())
    }
    pub fn discard_blank(&mut self, id: &str) -> Result<(), String> {
        let n = self.get(id)?;
        if n.blank() && !n.recording && !n.paused {
            fs::remove_file(self.path(id)?).map_err(|_| "Cannot remove blank note")?;
            self.index.remove(id);
            self.write_index()?;
        }
        Ok(())
    }
    pub fn empty_trash(&mut self) -> Result<(), String> {
        self.purge_at(u64::MAX)
    }
    fn purge_at(&mut self, at: u64) -> Result<(), String> {
        let ids: Vec<_> = self
            .index
            .values()
            .filter(|e| {
                e.deleted_at
                    .is_some_and(|d| at.saturating_sub(d) >= TRASH_MS)
            })
            .map(|e| e.id.clone())
            .collect();
        for id in ids {
            fs::remove_file(self.path(&id)?).map_err(|_| "Cannot remove deleted note")?;
            self.index.remove(&id);
            self.appends.remove(&id);
        }
        self.write_index()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!("chirp-library-test-{}", uuid::Uuid::new_v4())))
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn durable_private_recovery_search_and_exclusive_lock() {
        let temp = Temp::new();
        let mut lib = Library::open(&temp.0).unwrap();
        assert!(Library::open(&temp.0).is_err());
        let n = lib.create().unwrap();
        lib.set_recording(&n.id, true, false, false, "").unwrap();
        lib.segment(&n.id, "synthetic searchword".into(), 1200)
            .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(lib.path(&n.id).unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        drop(lib);
        let lib = Library::open(&temp.0).unwrap();
        let n = lib.get(&n.id).unwrap();
        assert!(n.recovered);
        assert!(!n.recording);
        assert_eq!(lib.list("searchword", false).len(), 1);
    }
    #[test]
    fn appends_merge_without_overwriting_edits_and_organize_is_versioned() {
        let temp = Temp::new();
        let mut lib = Library::open(&temp.0).unwrap();
        let n = lib.create().unwrap();
        let (_, sid) = lib.segment(&n.id, "Words".into(), 500).unwrap();
        lib.append_notes(&n.id, &sid, "- A new point", true)
            .unwrap();
        let n = lib
            .edit(&n.id, 0, "My edit".into(), Some("My title".into()))
            .unwrap();
        assert!(n.body.contains("My edit"));
        assert!(n.body.contains("new point"));
        assert!(lib.organize(&n.id, 1, "stale".into()).is_err());
        let n = lib
            .organize(&n.id, n.body_version, "# Other heading".into())
            .unwrap();
        assert_eq!(n.title, "My title");
        assert_eq!(
            lib.undo_organize(&n.id).unwrap().body,
            "My edit\n\n- A new point"
        );
        assert!(lib.edit(&n.id, 0, "stale edit".into(), None).is_err());
    }
    #[test]
    fn trash_restore_retention_and_blank_discard() {
        let temp = Temp::new();
        let mut lib = Library::open(&temp.0).unwrap();
        let n = lib.create().unwrap();
        lib.discard_blank(&n.id).unwrap();
        assert!(lib.list("", false).is_empty());
        let n = lib.create().unwrap();
        lib.edit(&n.id, 0, "- [ ] Task".into(), None).unwrap();
        lib.trash(&n.id, true).unwrap();
        assert!(lib.list("", false).is_empty());
        assert_eq!(lib.list("", true)[0].todos, 1);
        lib.trash(&n.id, false).unwrap();
        assert_eq!(lib.list("", false).len(), 1);
        lib.set_recording(&n.id, true, false, false, "").unwrap();
        assert!(lib.trash(&n.id, true).is_err());
        lib.set_recording(&n.id, false, false, false, "").unwrap();
        lib.trash(&n.id, true).unwrap();
        lib.empty_trash().unwrap();
        assert!(lib.get(&n.id).is_err());
    }
    #[test]
    fn unreadable_and_newer_records_are_kept() {
        let temp = Temp::new();
        let mut lib = Library::open(&temp.0).unwrap();
        let n = lib.create().unwrap();
        let path = lib.path(&n.id).unwrap();
        drop(lib);
        fs::write(&path, b"not json").unwrap();
        let lib = Library::open(&temp.0).unwrap();
        assert_eq!(lib.warnings, 1);
        assert!(path.exists());
    }
}
