//! Native audio stays outside the WebView; only 16 kHz mono PCM leaves this module.
use crate::protocol::Control;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tokio::sync::{mpsc, watch};

/// Streaming linear interpolation carries phase across callbacks, including 44.1 kHz.
struct Pcm {
    step: f64,
    next: f64,
    index: u64,
    previous: f32,
    bytes: Vec<u8>,
}
impl Pcm {
    fn new(rate: u32) -> Self {
        Self {
            step: rate as f64 / 16000.0,
            next: 0.0,
            index: 0,
            previous: 0.0,
            bytes: Vec::with_capacity(1600),
        }
    }
    fn sample(&mut self, value: f32, output: &mpsc::Sender<Result<Vec<u8>, String>>) -> bool {
        let value = if value.is_finite() {
            value.clamp(-1.0, 1.0)
        } else {
            0.0
        };
        while self.next <= self.index as f64 {
            let fraction = (self.next - (self.index as f64 - 1.0)).clamp(0.0, 1.0) as f32;
            let sample = self.previous + fraction * (value - self.previous);
            let signed = (sample * 32767.0).round() as i16;
            self.bytes.extend_from_slice(&signed.to_le_bytes());
            self.next += self.step;
            if self.bytes.len() == 1600
                && output
                    .try_send(Ok(std::mem::replace(
                        &mut self.bytes,
                        Vec::with_capacity(1600),
                    )))
                    .is_err()
            {
                return false;
            }
        }
        self.previous = value;
        self.index += 1;
        true
    }
}

fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    tx: mpsc::Sender<Result<Vec<u8>, String>>,
    failed: Arc<AtomicBool>,
) -> Result<(cpal::Stream, Arc<Mutex<Pcm>>), String>
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    let pcm = Arc::new(Mutex::new(Pcm::new(config.sample_rate.0)));
    let callback_pcm = pcm.clone();
    let channels = config.channels as usize;
    let errors = failed.clone();
    let stream = device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                let Ok(mut pcm) = callback_pcm.lock() else {
                    failed.store(true, Ordering::Relaxed);
                    return;
                };
                for frame in data.chunks_exact(channels) {
                    let mono = frame
                        .iter()
                        .map(|v| <f32 as cpal::FromSample<T>>::from_sample_(*v))
                        .sum::<f32>()
                        / channels as f32;
                    if !pcm.sample(mono, &tx) {
                        failed.store(true, Ordering::Relaxed);
                        break;
                    }
                }
            },
            move |_| {
                errors.store(true, Ordering::Relaxed);
            },
            None,
        )
        .map_err(|_| "Could not open the microphone".to_string())?;
    Ok((stream, pcm))
}

pub fn capture(tx: mpsc::Sender<Result<Vec<u8>, String>>, control: watch::Receiver<Control>) {
    std::thread::spawn(move || {
        let failed = Arc::new(AtomicBool::new(false));
        let start = || {
            let device = cpal::default_host()
                .default_input_device()
                .ok_or("No microphone is available")?;
            let supported = device
                .default_input_config()
                .map_err(|_| "Microphone format unavailable")?;
            let config: cpal::StreamConfig = supported.clone().into();
            let (stream, pcm) = match supported.sample_format() {
                cpal::SampleFormat::F32 => {
                    build::<f32>(&device, &config, tx.clone(), failed.clone())
                }
                cpal::SampleFormat::I16 => {
                    build::<i16>(&device, &config, tx.clone(), failed.clone())
                }
                cpal::SampleFormat::U16 => {
                    build::<u16>(&device, &config, tx.clone(), failed.clone())
                }
                _ => Err("Microphone format is not supported".into()),
            }?;
            stream
                .play()
                .map_err(|_| "Could not start the microphone")?;
            Ok::<_, String>((stream, pcm))
        };
        match start() {
            Ok((stream, pcm)) => {
                while *control.borrow() == Control::Running
                    && control.has_changed().is_ok()
                    && !failed.load(Ordering::Relaxed)
                {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                drop(stream);
                if *control.borrow() != Control::Cancel {
                    if let Ok(mut pcm) = pcm.lock() {
                        if !pcm.bytes.is_empty() {
                            let _ = tx.blocking_send(Ok(std::mem::take(&mut pcm.bytes)));
                        }
                    }
                }
                if failed.load(Ordering::Relaxed) {
                    let _ = tx.blocking_send(Err(
                        "Microphone failed or the server could not keep up".into(),
                    ));
                }
            }
            Err(error) => {
                let _ = tx.blocking_send(Err(error));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resampling_is_continuous_and_bounded() {
        for rate in [16000, 44100, 48000] {
            let (tx, mut rx) = mpsc::channel(64);
            let mut pcm = Pcm::new(rate);
            for _ in 0..rate {
                assert!(pcm.sample(0.5, &tx));
            }
            drop(tx);
            let mut bytes = Vec::new();
            while let Ok(chunk) = rx.try_recv() {
                bytes.extend(chunk.unwrap());
            }
            assert!(
                (30400..=32000).contains(&bytes.len()),
                "rate={rate} bytes={}",
                bytes.len()
            );
            assert!(bytes
                .as_chunks::<2>()
                .0
                .iter()
                .all(|b| (i16::from_le_bytes([b[0], b[1]]) - 16384).abs() <= 1));
        }
    }
    #[test]
    fn full_queue_causes_failure_instead_of_silent_audio_loss() {
        let (tx, _rx) = mpsc::channel(1);
        let mut pcm = Pcm::new(16000);
        for _ in 0..800 {
            assert!(pcm.sample(0.0, &tx));
        }
        let mut overflow = false;
        for _ in 0..800 {
            overflow |= !pcm.sample(0.0, &tx);
        }
        assert!(overflow);
    }
}
