use std::sync::{Arc, Mutex};

const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;
const MAX_FRAME_DIMENSION: u32 = 4096;
type FrameNotifier = Arc<dyn Fn(i64) + Send + Sync>;

/// Tightly packed, top-to-bottom, premultiplied sRGB RGBA8 pixels.
/// Dimensions and byte count are checked before a frame enters the mailbox.
#[derive(Debug)]
pub struct RgbaFrame {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) pixels: Vec<u8>,
}

impl RgbaFrame {
    pub fn new(width: u32, height: u32, pixels: Vec<u8>) -> Result<Self, String> {
        if width == 0 || height == 0 || width > MAX_FRAME_DIMENSION || height > MAX_FRAME_DIMENSION
        {
            return Err("RGBA frame dimensions must be between 1 and 4096".into());
        }
        let bytes = (width as usize)
            .checked_mul(height as usize)
            .and_then(|n| n.checked_mul(4))
            .filter(|n| *n > 0 && *n <= MAX_FRAME_BYTES)
            .ok_or("RGBA frame must be nonempty and at most 64 MiB")?;
        if pixels.len() != bytes {
            return Err(format!(
                "RGBA frame has {} bytes, expected {bytes}",
                pixels.len()
            ));
        }
        Ok(Self {
            width,
            height,
            pixels,
        })
    }
}

/// A bounded latest-frame mailbox. Publishing never touches GL or Flutter.
/// Older unpublished frames are replaced; only one wakeup can be pending.
#[derive(Clone)]
pub struct RgbaTexture {
    id: i64,
    state: Arc<Mutex<State>>,
}

#[derive(Default)]
struct State {
    frame: Option<Arc<RgbaFrame>>,
    generation: u64,
    notifier: Option<FrameNotifier>,
    notification_pending: bool,
}

impl RgbaTexture {
    pub fn new(id: i64) -> Result<Self, String> {
        if id <= 0 {
            return Err("external texture IDs must be positive".into());
        }
        Ok(Self {
            id,
            state: Arc::default(),
        })
    }

    pub fn id(&self) -> i64 {
        self.id
    }

    pub fn publish(&self, frame: RgbaFrame) {
        let notifier = {
            let mut state = self.state.lock().unwrap();
            state.frame = Some(Arc::new(frame));
            state.generation = state.generation.wrapping_add(1);
            take_notification(&mut state)
        };
        if let Some(notifier) = notifier {
            notifier(self.id);
        }
    }

    pub(crate) fn latest(&self) -> Option<(u64, Arc<RgbaFrame>)> {
        let state = self.state.lock().unwrap();
        state
            .frame
            .as_ref()
            .map(|frame| (state.generation, frame.clone()))
    }

    pub(crate) fn set_notifier(&self, notifier: Option<FrameNotifier>) {
        let notification = {
            let mut state = self.state.lock().unwrap();
            state.notifier = notifier;
            state.notification_pending = false;
            take_notification(&mut state)
        };
        if let Some(notifier) = notification {
            notifier(self.id);
        }
    }

    pub(crate) fn acknowledge_notification(&self) {
        self.state.lock().unwrap().notification_pending = false;
    }
}

fn take_notification(state: &mut State) -> Option<FrameNotifier> {
    if state.frame.is_none() || state.notification_pending {
        return None;
    }
    let notifier = state.notifier.clone()?;
    state.notification_pending = true;
    Some(notifier)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn frame(value: u8) -> RgbaFrame {
        RgbaFrame::new(1, 1, vec![value; 4]).unwrap()
    }

    #[test]
    fn rejects_invalid_frames_and_ids() {
        assert!(RgbaTexture::new(0).is_err());
        assert!(RgbaTexture::new(-1).is_err());
        assert!(RgbaFrame::new(0, 1, vec![]).is_err());
        assert!(RgbaFrame::new(u32::MAX, u32::MAX, vec![]).is_err());
        assert!(RgbaFrame::new(2, 1, vec![0; 4]).is_err());
        assert!(RgbaFrame::new(1, 4097, vec![0; 4097 * 4]).is_err());
    }

    #[test]
    fn latest_frame_replaces_old_frames_and_coalesces_wakeups() {
        let texture = RgbaTexture::new(7).unwrap();
        let wakeups = Arc::new(AtomicUsize::new(0));
        let count = wakeups.clone();
        texture.set_notifier(Some(Arc::new(move |id| {
            assert_eq!(id, 7);
            count.fetch_add(1, Ordering::Relaxed);
        })));
        texture.publish(frame(1));
        texture.publish(frame(2));
        assert_eq!(wakeups.load(Ordering::Relaxed), 1);
        assert_eq!(texture.latest().unwrap().1.pixels, vec![2; 4]);
        texture.acknowledge_notification();
        texture.publish(frame(3));
        assert_eq!(wakeups.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn registering_after_publish_notifies_and_detaching_stops_wakeups() {
        let texture = RgbaTexture::new(1).unwrap();
        texture.publish(frame(1));
        let wakeups = Arc::new(AtomicUsize::new(0));
        let count = wakeups.clone();
        texture.set_notifier(Some(Arc::new(move |_| {
            count.fetch_add(1, Ordering::Relaxed);
        })));
        assert_eq!(wakeups.load(Ordering::Relaxed), 1);
        texture.set_notifier(None);
        texture.publish(frame(2));
        assert_eq!(wakeups.load(Ordering::Relaxed), 1);
    }
}
