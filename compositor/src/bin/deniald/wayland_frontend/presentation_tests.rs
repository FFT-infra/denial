use super::*;
use smithay::reexports::wayland_server::backend::ClientData;
use smithay::reexports::wayland_server::protocol::wl_compositor::WlCompositor;
use smithay::reexports::wayland_server::{Client, Display, Resource};
use smithay::wayland::GlobalData;
use smithay::wayland::compositor::{
    CompositorClientState, CompositorHandler, CompositorState, with_surface_tree_upward,
};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, mpsc};

struct TestCompositor {
    compositor: CompositorState,
    surface: Option<WlSurface>,
}

#[derive(Default)]
struct TestClient(CompositorClientState);
impl ClientData for TestClient {}

impl CompositorHandler for TestCompositor {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client.get_data::<TestClient>().unwrap().0
    }

    fn new_surface(&mut self, surface: &WlSurface) {
        self.surface = Some(surface.clone());
    }

    fn commit(&mut self, _: &WlSurface) {}
}

smithay::delegate_dispatch2!(TestCompositor);

#[test]
fn feedback_lookup_completes_inside_a_locked_surface_tree_traversal() {
    let (done, result) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        // An isolated protocol connection exercises Smithay's real surface
        // locks without a compositor session, display, or rendered content.
        let mut display = Display::<TestCompositor>::new().unwrap();
        let mut handle = display.handle();
        let mut state = TestCompositor {
            compositor: CompositorState::new::<TestCompositor>(&handle),
            surface: None,
        };
        let (mut writer, reader) = UnixStream::pair().unwrap();
        let client = handle
            .insert_client(reader, Arc::new(TestClient::default()))
            .unwrap();
        let compositor = client
            .create_resource::<WlCompositor, _, TestCompositor>(&handle, 6, GlobalData)
            .unwrap();
        // wl_compositor.create_surface(new_id=2), using the server resource
        // directly so this test needs no client library or registry roundtrip.
        for word in [compositor.id().protocol_id(), 12_u32 << 16, 2] {
            writer.write_all(&word.to_ne_bytes()).unwrap();
        }
        display.dispatch_clients(&mut state).unwrap();
        let surface = state
            .surface
            .as_ref()
            .expect("create_surface was dispatched");
        capture_surface_feedback(surface);
        let mut visited = false;
        with_surface_tree_upward(
            surface,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |_, states, _| {
                assert!(surface_feedback(states).is_none());
                visited = true;
            },
            |_, _, _| true,
        );
        assert!(visited);
        // Metadata inspection shares this same locked traversal contract.
        // It must use SurfaceData and the traversal parent, never re-enter
        // with_states/get_parent from a callback.
        assert!(super::super::surface_pipeline::surface_tree_metadata_changed(surface));
        assert!(!super::super::surface_pipeline::surface_tree_metadata_changed(surface));
        done.send(()).unwrap();
    });
    result
        .recv_timeout(Duration::from_secs(2))
        .expect("feedback lookup deadlocked while the surface tree held its lock");
    worker.join().unwrap();
}

#[test]
fn subsurface_order_and_removal_invalidate_the_same_root_from_a_child() {
    use super::super::surface_pipeline::surface_tree_metadata_changed;
    use smithay::reexports::wayland_server::protocol::wl_subcompositor::WlSubcompositor;
    let (done, result) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let mut display = Display::<TestCompositor>::new().unwrap();
        let mut handle = display.handle();
        let mut state = TestCompositor {
            compositor: CompositorState::new::<TestCompositor>(&handle),
            surface: None,
        };
        let (mut writer, reader) = UnixStream::pair().unwrap();
        let client = handle
            .insert_client(reader, Arc::new(TestClient::default()))
            .unwrap();
        let compositor = client
            .create_resource::<WlCompositor, _, TestCompositor>(&handle, 6, GlobalData)
            .unwrap();
        let subcompositor = client
            .create_resource::<WlSubcompositor, _, TestCompositor>(&handle, 1, GlobalData)
            .unwrap();
        fn send(writer: &mut UnixStream, words: &[u32]) {
            for word in words {
                writer.write_all(&word.to_ne_bytes()).unwrap();
            }
        }
        send(&mut writer, &[compositor.id().protocol_id(), 12 << 16, 2]);
        display.dispatch_clients(&mut state).unwrap();
        let root = state.surface.clone().unwrap();
        assert!(surface_tree_metadata_changed(&root));
        send(&mut writer, &[compositor.id().protocol_id(), 12 << 16, 3]);
        display.dispatch_clients(&mut state).unwrap();
        let child = state.surface.clone().unwrap();
        // get_subsurface(new_id=4, surface=3, parent=2).
        send(
            &mut writer,
            &[subcompositor.id().protocol_id(), (20 << 16) | 1, 4, 3, 2],
        );
        display.dispatch_clients(&mut state).unwrap();
        assert!(surface_tree_metadata_changed(&root));
        assert!(!surface_tree_metadata_changed(&child));
        // place_below(parent): order changes without a new buffer.
        send(&mut writer, &[4, (12 << 16) | 3, 2]);
        display.dispatch_clients(&mut state).unwrap();
        assert!(surface_tree_metadata_changed(&child));
        assert!(!surface_tree_metadata_changed(&root));
        // Destroy only the subsurface role; the wl_surface remains alive.
        send(&mut writer, &[4, 8 << 16]);
        display.dispatch_clients(&mut state).unwrap();
        assert!(surface_tree_metadata_changed(&root));
        assert!(!surface_tree_metadata_changed(&root));
        done.send(()).unwrap();
    });
    result
        .recv_timeout(Duration::from_secs(2))
        .expect("surface tree metadata traversal deadlocked");
    worker.join().unwrap();
}
