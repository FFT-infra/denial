fn main() {
    // SAFETY: this runs before the event loop, Flutter, EGL or worker threads.
    unsafe { denial_app::prepare_graphics_environment() };
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let Some(config) = denial_app::Config::parse()? else {
            return Ok(());
        };
        if config.check {
            config.check()
        } else {
            denial_app::run(config)
        }
    })();
    if let Err(error) = result {
        eprintln!("denial-app: {error}");
        std::process::exit(1);
    }
}
