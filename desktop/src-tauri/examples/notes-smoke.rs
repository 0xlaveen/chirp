//! Explicit real-server smoke. All inputs are synthetic; no transcript or token is printed.
use chirp_desktop::{files, library::Library, notes, protocol::Control, settings::Settings};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tokio::sync::{mpsc, watch};
#[tokio::main]
async fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    assert_eq!(
        args.len(),
        5,
        "URL token-file PCM16LE-file library-directory"
    );
    let settings = Settings {
        url: args[1].to_string_lossy().into_owned(),
        ..Settings::default()
    };
    let token = std::fs::read_to_string(&args[2])
        .expect("throwaway token missing")
        .trim()
        .to_string();
    let pcm = std::fs::read(&args[3]).expect("synthetic PCM missing");
    assert!(!pcm.is_empty());
    assert_eq!(pcm.len() % 2, 0);
    let duration = pcm.len() as u64 * 1000 / 32000;
    let root = PathBuf::from(&args[4]);
    let lib = Arc::new(Mutex::new(
        Library::open(&root).expect("private library unavailable"),
    ));
    let id = lib.lock().unwrap().create().unwrap().id;
    lib.lock()
        .unwrap()
        .set_recording(&id, true, false, false, "")
        .unwrap();
    let (tx, source) = mpsc::channel(2400);
    let mut repeated = pcm.clone();
    repeated.extend_from_slice(&vec![0; 16000]);
    repeated.extend_from_slice(&pcm);
    let total = repeated.len() as u64 * 1000 / 32000;
    for bytes in repeated.chunks(1600) {
        tx.send(Ok(bytes.to_vec())).await.unwrap();
    }
    drop(tx);
    let (_control, rx) = watch::channel(Control::Stop);
    let key = id.clone();
    let store = lib.clone();
    notes::segments(
        settings.clone(),
        token.clone(),
        rx,
        source,
        pcm.len() + 16000,
        move |text, ms| {
            if text.trim().is_empty() {
                return Err("Real ASR returned no text".into());
            }
            store.lock().unwrap().segment(&key, text, ms).map(|_| ())
        },
        |_| {},
    )
    .await
    .expect("real Notes segment stream failed");
    let segments = lib.lock().unwrap().get(&id).unwrap().segments;
    assert_eq!(segments.len(), 2);
    assert_eq!(segments.iter().map(|s| s.duration_ms).sum::<u64>(), total);
    let all = segments
        .iter()
        .map(|s| s.text.to_lowercase())
        .collect::<Vec<_>>()
        .join(" ");
    for required in ["budget", "review", "tuesday"] {
        assert!(
            all.contains(required),
            "Real ASR missed a synthetic keyword"
        );
    }
    let first = &segments[0];
    let markdown = notes::smart(&settings, &token, &first.text, false)
        .await
        .expect("real smart notes failed");
    lib.lock()
        .unwrap()
        .append_notes(&id, &first.id, &markdown, true)
        .unwrap();
    let second = &segments[1];
    lib.lock()
        .unwrap()
        .append_notes(&id, &second.id, &second.text, false)
        .unwrap();
    let n = lib.lock().unwrap().get(&id).unwrap();
    let edited = lib
        .lock()
        .unwrap()
        .edit(
            &id,
            n.body_version,
            format!("{}\n\n- [ ] Synthetic follow-up", n.body),
            Some("Synthetic Notes proof".into()),
        )
        .unwrap();
    lib.lock()
        .unwrap()
        .set_recording(&id, false, false, false, "")
        .unwrap();
    assert_eq!(lib.lock().unwrap().list("follow-up", false).len(), 1);
    files::atomic(&root.join("export.md"), edited.markdown().as_bytes()).unwrap();
    lib.lock().unwrap().trash(&id, true).unwrap();
    assert_eq!(lib.lock().unwrap().list("", true).len(), 1);
    lib.lock().unwrap().trash(&id, false).unwrap();
    drop(lib);
    let reopened = Library::open(&root).unwrap();
    let n = reopened.get(&id).unwrap();
    assert_eq!(n.segments.len(), 2);
    assert_eq!(n.title, "Synthetic Notes proof");
    assert!(!n.recording);
    assert!(!n.body.is_empty());
    println!("Notes: real ONNX streams, Stop drain, smart structure, durable edit, search, export and trash/restore passed ({} segments, {} ms source)",n.segments.len(),duration);
}
