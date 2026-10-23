//! `zwp_input_timestamps_manager_v1`: input event times in nanoseconds.
//!
//! `wl_keyboard`, `wl_pointer` and `wl_touch` carry 32-bit milliseconds.
//! libinput gives Denial microseconds on `CLOCK_MONOTONIC`; a subscribed
//! client receives that time in a `timestamp` event right before the input
//! event it belongs to. Smithay writes the input events itself, so the seat
//! focus targets in `focus.rs` send the timestamp just before forwarding.

use smithay::input::Seat;
use smithay::reexports::wayland_protocols::wp::input_timestamps::zv1::server::{
    zwp_input_timestamps_manager_v1::{self, ZwpInputTimestampsManagerV1},
    zwp_input_timestamps_v1::{self, ZwpInputTimestampsV1},
};
use smithay::reexports::wayland_server::backend::{ClientId, GlobalId, ObjectId};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource,
};

use super::super::RuntimeState;

#[derive(Debug)]
pub(super) struct InputTimestamps {
    _global: GlobalId,
    subscriptions: Vec<Subscription>,
    /// libinput time of the event being dispatched, in microseconds.
    event_usec: Option<u64>,
}

#[derive(Debug)]
struct Subscription {
    resource: ZwpInputTimestampsV1,
    /// The `wl_keyboard`, `wl_pointer` or `wl_touch` it follows.
    device: ObjectId,
}

/// Which seat device an input event goes through.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum InputDevice {
    Keyboard,
    Pointer,
    Touch,
}

impl InputTimestamps {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display.create_global::<RuntimeState, ZwpInputTimestampsManagerV1, _>(1, ()),
            subscriptions: Vec::new(),
            event_usec: None,
        }
    }

    /// Mark the libinput event whose time the next input events carry.
    pub(super) fn begin_event(&mut self, usec: Option<u64>) {
        self.event_usec = usec;
    }

    fn subscribe(&mut self, resource: ZwpInputTimestampsV1, device: ObjectId) {
        self.subscriptions
            .retain(|subscription| subscription.resource.is_alive());
        self.subscriptions.push(Subscription { resource, device });
    }

    fn unsubscribe(&mut self, resource: &ObjectId) {
        self.subscriptions
            .retain(|subscription| subscription.resource.id() != *resource);
    }

    /// Send the time of the event stamped `millis` to every subscription on
    /// `devices`, the device objects Smithay is about to write it to.
    fn send(&self, devices: impl Iterator<Item = ObjectId>, millis: u32) {
        if self.subscriptions.is_empty() {
            return;
        }
        let Some(usec) = full_time(self.event_usec, millis) else {
            return;
        };
        let (seconds_hi, seconds_lo, nanos) = split(usec);
        for device in devices {
            for subscription in &self.subscriptions {
                if subscription.device == device {
                    subscription
                        .resource
                        .timestamp(seconds_hi, seconds_lo, nanos);
                }
            }
        }
    }
}

/// The full time of an input event stamped `millis`, when it is the libinput
/// event being dispatched (`event_usec`). A compositor-made event (a reset, a
/// replayed gesture) keeps its millisecond time alone.
fn full_time(event_usec: Option<u64>, millis: u32) -> Option<u64> {
    // Smithay's millisecond time is the libinput time truncated to u32.
    #[allow(clippy::cast_possible_truncation)]
    event_usec.filter(|usec| (usec / 1_000) as u32 == millis)
}

/// The protocol's `tv_sec_hi`, `tv_sec_lo` and `tv_nsec` for `usec`.
#[allow(clippy::cast_possible_truncation)]
fn split(usec: u64) -> (u32, u32, u32) {
    let seconds = usec / 1_000_000;
    (
        (seconds >> 32) as u32,
        seconds as u32,
        (usec % 1_000_000 * 1_000) as u32,
    )
}

/// Send the full time of the event stamped `millis` that Smithay is about to
/// write to `surface`'s client through `device`.
pub(super) fn send(
    state: &RuntimeState,
    seat: &Seat<RuntimeState>,
    device: InputDevice,
    surface: &WlSurface,
    millis: u32,
) {
    let Some(frontend) = state.wayland.as_ref() else {
        return;
    };
    let timestamps = &frontend.input_timestamps;
    if timestamps.subscriptions.is_empty() {
        return;
    }
    let Some(client) = surface.client() else {
        return;
    };
    match device {
        InputDevice::Keyboard => {
            if let Some(keyboard) = seat.get_keyboard() {
                timestamps.send(keyboard.client_keyboards(&client).map(|k| k.id()), millis);
            }
        }
        InputDevice::Pointer => {
            if let Some(pointer) = seat.get_pointer() {
                timestamps.send(pointer.client_pointers(&client).map(|p| p.id()), millis);
            }
        }
        InputDevice::Touch => {
            if let Some(touch) = seat.get_touch() {
                timestamps.send(touch.client_touch(&client).map(|t| t.id()), millis);
            }
        }
    }
}

impl GlobalDispatch<ZwpInputTimestampsManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<ZwpInputTimestampsManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<ZwpInputTimestampsManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &ZwpInputTimestampsManagerV1,
        request: zwp_input_timestamps_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        let (id, device) = match request {
            zwp_input_timestamps_manager_v1::Request::GetKeyboardTimestamps { id, keyboard } => {
                (id, keyboard.id())
            }
            zwp_input_timestamps_manager_v1::Request::GetPointerTimestamps { id, pointer } => {
                (id, pointer.id())
            }
            zwp_input_timestamps_manager_v1::Request::GetTouchTimestamps { id, touch } => {
                (id, touch.id())
            }
            zwp_input_timestamps_manager_v1::Request::Destroy => return,
            _ => return,
        };
        let resource = data_init.init(id, ());
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.input_timestamps.subscribe(resource, device);
        }
    }
}

impl Dispatch<ZwpInputTimestampsV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &ZwpInputTimestampsV1,
        request: zwp_input_timestamps_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        if matches!(request, zwp_input_timestamps_v1::Request::Destroy)
            && let Some(frontend) = state.wayland.as_mut()
        {
            frontend.input_timestamps.unsubscribe(&resource.id());
        }
    }

    fn destroyed(state: &mut Self, _client: ClientId, resource: &ZwpInputTimestampsV1, _data: &()) {
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.input_timestamps.unsubscribe(&resource.id());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_split_into_protocol_fields() {
        assert_eq!(split(35_473_078_386_118), (0, 35_473_078, 386_118_000));
        assert_eq!(
            split(((1_u64 << 32) + 7) * 1_000_000 + 999_999),
            (1, 7, 999_999_000)
        );
    }

    #[test]
    fn only_the_dispatched_libinput_event_has_a_full_time() {
        assert_eq!(full_time(None, 35_473_078), None);
        assert_eq!(
            full_time(Some(35_473_078_386), 35_473_078),
            Some(35_473_078_386)
        );
        assert_eq!(full_time(Some(35_473_078_386), 35_473_079), None);
        // Millisecond times wrap after 49.7 days; the low 32 bits still match.
        let late = ((1_u64 << 32) + 5) * 1_000 + 250;
        assert_eq!(full_time(Some(late), 5), Some(late));
    }
}
