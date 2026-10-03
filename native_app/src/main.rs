#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

mod app;
mod config;
mod egl;
mod file_chooser;
mod platform;
mod renderer;

// Read-only reuse of Denial's text editor needs this small value-type adapter.
// No Wayland server or compositor implementation is linked into this runner.
mod wayland_frontend {
    pub(crate) mod input_method {
        #[derive(Clone, Debug, Default, Eq, PartialEq)]
        pub(crate) struct InputMethodTransaction {
            pub commit_string: Option<String>,
            pub preedit_string: Option<(String, i32, i32)>,
            pub delete_surrounding: Option<(u32, u32)>,
        }
    }
}

fn main() {
    // Mesa's framebuffer-fetch path loses earlier layers when the final
    // backdrop filter switches to the window target. Keep ordinary sampling.
    let mut extensions = std::env::var_os("MESA_EXTENSION_OVERRIDE").unwrap_or_default();
    extensions.push(" -GL_EXT_shader_framebuffer_fetch");
    // SAFETY: this runs before the event loop, Flutter, EGL or worker threads.
    unsafe { std::env::set_var("MESA_EXTENSION_OVERRIDE", extensions) };

    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let Some(config) = config::Config::parse()? else {
            return Ok(());
        };
        if config.check {
            config.check()
        } else {
            app::run(config)
        }
    })();
    if let Err(error) = result {
        eprintln!("denial-app: {error}");
        std::process::exit(1);
    }
}
