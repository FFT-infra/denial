//! Settings file selection through the system portal, without a toolkit runner.
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::atomic::{AtomicBool, Ordering},
};
use zbus::{
    blocking::{Connection, Proxy},
    zvariant::{OwnedObjectPath, OwnedValue, Value as BusValue},
};

static OPEN: AtomicBool = AtomicBool::new(false);

pub fn handles(channel: &str, data: &[u8]) -> bool {
    channel == "denial/settings_activation"
        && serde_json::from_slice::<Value>(data)
            .ok()
            .is_some_and(|call| {
                matches!(
                    call["method"].as_str(),
                    Some("pickProfileImage" | "pickCursorZip")
                )
            })
}

pub fn run(data: &[u8]) -> Vec<u8> {
    if OPEN.swap(true, Ordering::AcqRel) {
        return json!(["file-chooser-busy", "A file chooser is already open", null])
            .to_string()
            .into_bytes();
    }
    let result = choose(data);
    OPEN.store(false, Ordering::Release);
    match result {
        Ok(path) => json!([path]),
        Err(error) => json!(["file-chooser", error.to_string(), null]),
    }
    .to_string()
    .into_bytes()
}

fn choose(data: &[u8]) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let call: Value = serde_json::from_slice(data)?;
    let zip = call["method"] == "pickCursorZip";
    let title = call["args"]["title"].as_str().unwrap_or(if zip {
        "Import cursor ZIP"
    } else {
        "Choose photo"
    });
    let connection = Connection::session()?;
    let name = connection
        .unique_name()
        .ok_or("Portal bus has no unique name")?
        .as_str()
        .trim_start_matches(':')
        .replace('.', "_");
    let token = format!("denial_{}", std::process::id());
    let path = format!("/org/freedesktop/portal/desktop/request/{name}/{token}");
    let request = Proxy::new(
        &connection,
        "org.freedesktop.portal.Desktop",
        path.as_str(),
        "org.freedesktop.portal.Request",
    )?;
    // Subscribe before OpenFile: a fast response must not be lost.
    let mut responses = request.receive_signal("Response")?;
    let portal = Proxy::new(
        &connection,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.FileChooser",
    )?;
    let filters = if zip {
        vec![("Cursor ZIP archives", vec![(0u32, "*.[zZ][iI][pP]")])]
    } else {
        vec![(
            "Images",
            vec![
                (1u32, "image/png"),
                (1, "image/jpeg"),
                (1, "image/webp"),
                (1, "image/gif"),
                (1, "image/bmp"),
            ],
        )]
    };
    let mut options = HashMap::new();
    options.insert("handle_token", BusValue::from(token.as_str()));
    options.insert("multiple", BusValue::from(false));
    options.insert("filters", BusValue::from(filters));
    if let Some(label) = call["args"]["choose"].as_str() {
        options.insert("accept_label", BusValue::from(label));
    }
    let handle: OwnedObjectPath = portal.call("OpenFile", &("", title, options))?;
    if handle.as_str() != path {
        return Err("Portal returned an unexpected request path".into());
    }
    let response = responses.next().ok_or("Portal disconnected")?;
    let (code, mut results): (u32, HashMap<String, OwnedValue>) = response.body().deserialize()?;
    if code == 1 {
        return Ok(None);
    }
    if code != 0 {
        return Err("File chooser failed".into());
    }
    let uris = Vec::<String>::try_from(results.remove("uris").ok_or("Missing selected file")?)?;
    let uri = url::Url::parse(uris.first().ok_or("No selected file")?)?;
    let path = uri
        .to_file_path()
        .map_err(|_| "The selected file must be local")?;
    Ok(Some(
        path.into_os_string()
            .into_string()
            .map_err(|_| "File path is not UTF-8")?,
    ))
}
