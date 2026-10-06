use std::{
    ffi::{CStr, c_char, c_void},
    ptr,
};
use wayland_client::Connection;
use wayland_egl::WlEglSurface;

type Handle = *mut c_void;

#[link(name = "EGL")]
unsafe extern "C" {
    fn eglGetPlatformDisplay(platform: u32, native: Handle, attributes: *const isize) -> Handle;
    fn eglInitialize(display: Handle, major: *mut i32, minor: *mut i32) -> u32;
    fn eglTerminate(display: Handle) -> u32;
    fn eglBindAPI(api: u32) -> u32;
    fn eglChooseConfig(
        display: Handle,
        attributes: *const i32,
        configs: *mut Handle,
        size: i32,
        count: *mut i32,
    ) -> u32;
    fn eglGetConfigAttrib(display: Handle, config: Handle, attribute: i32, value: *mut i32) -> u32;
    fn eglCreateContext(
        display: Handle,
        config: Handle,
        shared: Handle,
        attributes: *const i32,
    ) -> Handle;
    fn eglDestroyContext(display: Handle, context: Handle) -> u32;
    fn eglCreateWindowSurface(
        display: Handle,
        config: Handle,
        window: Handle,
        attributes: *const i32,
    ) -> Handle;
    fn eglDestroySurface(display: Handle, surface: Handle) -> u32;
    fn eglMakeCurrent(display: Handle, draw: Handle, read: Handle, context: Handle) -> u32;
    fn eglSwapInterval(display: Handle, interval: i32) -> u32;
    fn eglSwapBuffers(display: Handle, surface: Handle) -> u32;
    fn eglQueryString(display: Handle, name: i32) -> *const c_char;
    fn eglGetError() -> i32;
    fn eglGetProcAddress(name: *const c_char) -> *mut c_void;
}

// EGL handles are opaque tokens. Each context is used by its designated
// Flutter thread only; storing tokens does not share a current GL context.
pub struct Egl {
    display: usize,
    render: usize,
    resource: usize,
    surface: usize,
    _connection: Connection,
}

impl Egl {
    pub fn new(connection: &Connection, window: &WlEglSurface) -> Result<Self, String> {
        let mut egl = Self {
            display: 0,
            render: 0,
            resource: 0,
            surface: 0,
            _connection: connection.clone(),
        };
        // SAFETY: the cloned connection keeps the native wl_display alive.
        egl.display = unsafe {
            eglGetPlatformDisplay(
                0x31d8,
                connection.backend().display_ptr().cast(),
                ptr::null(),
            )
        } as usize;
        if egl.display == 0 {
            return Err(last_error("get Wayland EGL display"));
        }
        // SAFETY: EGL accepts null version outputs for this live display.
        if unsafe { eglInitialize(egl.display(), ptr::null_mut(), ptr::null_mut()) } == 0 {
            return Err(last_error("initialize EGL"));
        }
        // SAFETY: this only selects the calling thread's client API.
        if unsafe { eglBindAPI(0x30a0) } == 0 {
            return Err(last_error("select GLES"));
        }
        // A separate upload context needs no window. Mesa/Denial already
        // provide this extension; fail clearly rather than silently use GTK.
        // SAFETY: the display is initialized; EGL owns the returned string.
        let extensions = unsafe { eglQueryString(egl.display(), 0x3055) };
        if extensions.is_null() {
            return Err(last_error("query EGL extensions"));
        }
        // SAFETY: a successful eglQueryString returns a NUL-terminated string.
        if !unsafe { CStr::from_ptr(extensions) }
            .to_string_lossy()
            .split_whitespace()
            .any(|e| e == "EGL_KHR_surfaceless_context")
        {
            return Err("EGL_KHR_surfaceless_context is required".into());
        }
        const NONE: i32 = 0x3038;
        let attributes = [
            0x3033, 0x0004, // EGL_SURFACE_TYPE / WINDOW_BIT
            0x3040, 0x0040, // EGL_RENDERABLE_TYPE / OPENGL_ES3_BIT
            0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, // RGBA8
            NONE,
        ];
        let (mut config, mut count) = (ptr::null_mut(), 0);
        // SAFETY: the attribute list is terminated and both outputs are writable.
        if unsafe {
            eglChooseConfig(
                egl.display(),
                attributes.as_ptr(),
                &mut config,
                1,
                &mut count,
            )
        } == 0
            || count == 0
        {
            return Err(last_error("choose alpha-capable GLES3 config"));
        }
        let mut alpha = 0;
        // SAFETY: this config belongs to the initialized display.
        if unsafe { eglGetConfigAttrib(egl.display(), config, 0x3021, &mut alpha) } == 0
            || alpha < 8
        {
            return Err("EGL did not supply an eight-bit alpha channel".into());
        }
        let context_attributes = [0x3098, 3, NONE];
        // SAFETY: config is valid and the terminated attributes request GLES3.
        egl.render = unsafe {
            eglCreateContext(
                egl.display(),
                config,
                ptr::null_mut(),
                context_attributes.as_ptr(),
            )
        } as usize;
        if egl.render == 0 {
            return Err(last_error("create render context"));
        }
        // SAFETY: the render context is live and may share objects with another context.
        egl.resource = unsafe {
            eglCreateContext(
                egl.display(),
                config,
                egl.render as Handle,
                context_attributes.as_ptr(),
            )
        } as usize;
        if egl.resource == 0 {
            return Err(last_error("create shared resource context"));
        }
        // SAFETY: window is alive and remains alive until after this EGL surface.
        egl.surface = unsafe {
            eglCreateWindowSurface(egl.display(), config, window.ptr() as Handle, ptr::null())
        } as usize;
        if egl.surface == 0 {
            return Err(last_error("create Wayland EGL surface"));
        }
        if !egl.make_render_current() {
            return Err(last_error("make render context current"));
        }
        // Frame callbacks pace Flutter; EGL must not add a second vsync wait.
        // SAFETY: the window context is current on this initialization thread.
        let swap_interval_ok = unsafe { eglSwapInterval(egl.display(), 0) } != 0;
        if !egl.clear_current() {
            return Err(last_error("release initial EGL context"));
        }
        if !swap_interval_ok {
            return Err(last_error("set EGL swap interval"));
        }
        Ok(egl)
    }

    fn display(&self) -> Handle {
        self.display as Handle
    }

    pub fn make_render_current(&self) -> bool {
        // SAFETY: Flutter invokes this exclusively on its render thread.
        unsafe {
            eglMakeCurrent(
                self.display(),
                self.surface as Handle,
                self.surface as Handle,
                self.render as Handle,
            ) != 0
        }
    }

    pub fn make_resource_current(&self) -> bool {
        // SAFETY: Flutter's resource context is separate from its render context.
        unsafe {
            eglMakeCurrent(
                self.display(),
                ptr::null_mut(),
                ptr::null_mut(),
                self.resource as Handle,
            ) != 0
        }
    }

    pub fn clear_current(&self) -> bool {
        // SAFETY: null handles release only the calling thread's bindings.
        unsafe {
            eglMakeCurrent(
                self.display(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
            ) != 0
        }
    }

    pub fn swap(&self) -> bool {
        // SAFETY: called on the render thread with its window context current.
        unsafe { eglSwapBuffers(self.display(), self.surface as Handle) != 0 }
    }

    pub fn resolve(name: &CStr) -> *mut c_void {
        // SAFETY: the borrowed name is NUL-terminated; EGL owns proc addresses.
        unsafe { eglGetProcAddress(name.as_ptr()) }
    }
}

impl Drop for Egl {
    fn drop(&mut self) {
        // SAFETY: the engine is shut down before this owner is dropped; no
        // callback can still use these handles. Zero denotes an absent handle.
        unsafe {
            if self.surface != 0 {
                eglDestroySurface(self.display(), self.surface as Handle);
            }
            if self.resource != 0 {
                eglDestroyContext(self.display(), self.resource as Handle);
            }
            if self.render != 0 {
                eglDestroyContext(self.display(), self.render as Handle);
            }
            if self.display != 0 {
                eglTerminate(self.display());
            }
        }
    }
}

pub fn last_error(operation: &str) -> String {
    // SAFETY: eglGetError has no arguments and returns the caller's error state.
    format!("{operation}: EGL error {:#x}", unsafe { eglGetError() })
}
