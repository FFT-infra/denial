//! Wayland contacts retain independent Flutter lifecycles and logical positions.

use std::{collections::BTreeMap, mem::size_of};

use denial_flutter_engine::sys;

#[derive(Default)]
pub(crate) struct TouchInput {
    contacts: BTreeMap<i32, (f64, f64)>,
}

pub(crate) struct TouchEvent {
    phase: sys::FlutterPointerPhase,
    id: i32,
    position: (f64, f64),
}

impl TouchEvent {
    pub(crate) fn into_flutter(self, scale: u32, timestamp: usize) -> sys::FlutterPointerEvent {
        sys::FlutterPointerEvent {
            struct_size: size_of::<sys::FlutterPointerEvent>(),
            phase: self.phase,
            timestamp,
            x: self.position.0 * f64::from(scale),
            y: self.position.1 * f64::from(scale),
            // Wayland contact IDs are non-negative; reserve device zero for the mouse.
            device: self.id.checked_add(1).unwrap_or(i32::MIN),
            device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindTouch,
            ..Default::default()
        }
    }
}

impl TouchInput {
    pub(crate) fn down(&mut self, id: i32, position: (f64, f64)) -> Vec<TouchEvent> {
        let mut events = self.finish(id, sys::FlutterPointerPhase_kCancel);
        self.contacts.insert(id, position);
        events.extend([
            TouchEvent {
                phase: sys::FlutterPointerPhase_kAdd,
                id,
                position,
            },
            TouchEvent {
                phase: sys::FlutterPointerPhase_kDown,
                id,
                position,
            },
        ]);
        events
    }

    pub(crate) fn motion(&mut self, id: i32, position: (f64, f64)) -> Vec<TouchEvent> {
        let Some(previous) = self.contacts.get_mut(&id) else {
            return Vec::new();
        };
        *previous = position;
        vec![TouchEvent {
            phase: sys::FlutterPointerPhase_kMove,
            id,
            position,
        }]
    }

    pub(crate) fn up(&mut self, id: i32) -> Vec<TouchEvent> {
        self.finish(id, sys::FlutterPointerPhase_kUp)
    }

    pub(crate) fn cancel(&mut self) -> Vec<TouchEvent> {
        std::mem::take(&mut self.contacts)
            .into_iter()
            .flat_map(|(id, position)| {
                [
                    TouchEvent {
                        phase: sys::FlutterPointerPhase_kCancel,
                        id,
                        position,
                    },
                    TouchEvent {
                        phase: sys::FlutterPointerPhase_kRemove,
                        id,
                        position,
                    },
                ]
            })
            .collect()
    }

    fn finish(&mut self, id: i32, phase: sys::FlutterPointerPhase) -> Vec<TouchEvent> {
        let Some(position) = self.contacts.remove(&id) else {
            return Vec::new();
        };
        vec![
            TouchEvent {
                phase,
                id,
                position,
            },
            TouchEvent {
                phase: sys::FlutterPointerPhase_kRemove,
                id,
                position,
            },
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sys::{
        FlutterPointerPhase_kAdd as ADD, FlutterPointerPhase_kCancel as CANCEL,
        FlutterPointerPhase_kDown as DOWN, FlutterPointerPhase_kMove as MOVE,
        FlutterPointerPhase_kRemove as REMOVE, FlutterPointerPhase_kUp as UP,
    };

    fn phases(events: &[TouchEvent]) -> Vec<sys::FlutterPointerPhase> {
        events.iter().map(|event| event.phase).collect()
    }

    #[test]
    fn contacts_have_independent_lifecycles_and_scaled_positions() {
        let mut input = TouchInput::default();
        let first = input.down(0, (10.5, 20.25));
        assert_eq!(phases(&first), [ADD, DOWN]);
        let event = first.into_iter().last().unwrap().into_flutter(2, 42);
        assert_eq!((event.x, event.y), (21.0, 40.5));
        assert_eq!(event.device, 1);
        assert_eq!(
            event.device_kind,
            sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindTouch
        );
        assert_eq!(event.timestamp, 42);
        assert_eq!(phases(&input.down(7, (30.0, 40.0))), [ADD, DOWN]);
        assert_eq!(phases(&input.motion(0, (11.0, 22.0))), [MOVE]);
        let up = input.up(0);
        assert_eq!(phases(&up), [UP, REMOVE]);
        assert!(up.iter().all(|event| event.position == (11.0, 22.0)));
        let remaining = input.up(7);
        assert_eq!(phases(&remaining), [UP, REMOVE]);
        assert_eq!(remaining[0].position, (30.0, 40.0));
        assert!(input.motion(0, (90.0, 90.0)).is_empty());
        assert!(input.up(0).is_empty());
    }

    #[test]
    fn compositor_gestures_and_seat_removal_cancel_every_contact() {
        let mut input = TouchInput::default();
        input.down(0, (10.0, 20.0));
        input.down(1, (30.0, 40.0));
        let canceled = input.cancel();
        assert_eq!(phases(&canceled), [CANCEL, REMOVE, CANCEL, REMOVE]);
        assert_eq!((canceled[0].id, canceled[2].id), (0, 1));
        assert!(input.up(0).is_empty());
        assert!(input.up(1).is_empty());
        assert!(input.cancel().is_empty());
        assert_eq!(phases(&input.down(0, (50.0, 60.0))), [ADD, DOWN]);
    }
}
