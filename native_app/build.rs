use std::{env, fs, path::PathBuf};

fn main() {
    let mut bindings = Vec::new();
    gl_generator::Registry::new(
        gl_generator::Api::Gles2,
        (3, 0),
        gl_generator::Profile::Core,
        gl_generator::Fallbacks::All,
        [],
    )
    .write_bindings(gl_generator::StaticGenerator, &mut bindings)
    .expect("generate GLES 3 bindings");
    // gl_generator predates edition 2024's explicit unsafe extern blocks.
    let bindings = String::from_utf8(bindings)
        .expect("GL bindings are UTF-8")
        .replace("extern \"system\" {", "unsafe extern \"system\" {");
    fs::write(
        PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("gles.rs"),
        bindings,
    )
    .expect("write GLES bindings");
    println!("cargo:rustc-link-lib=GLESv2");
    println!("cargo:rerun-if-changed=build.rs");
}
