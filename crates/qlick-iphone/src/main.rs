//! Qlick Lab's iPhone helper: QLab's shared folder (its Documents) over the cable, read only.
//!
//! One command per run, its answers as JSON lines on stdout (an error as `{"error": …, "state": …}`):
//!
//! - `watch`: the iPhones plugged in now (`{"event": "attached", …}` each), then one line per one plugged in or out,
//!   until stdin closes.
//! - `probe UDID`: `{"udid", "name", "state"}`, `state` one of `ready`, `locked`, `untrusted`, `no_qlab`, `error`.
//! - `pair UDID`: asks the iPhone to trust this Mac (the iPhone shows the question), then answers as `probe`.
//! - `list UDID`: every file of QLab's folder, `{"path", "size", "modified"}` (path relative to Documents).
//! - `request-delete UDID`: the JSON on stdin written as a deletion request in QLab's folder
//!   (`.qlab-delete-requests/<uuid>.json`, through a hidden file renamed into place): QLab carries it out. The only
//!   thing this helper ever writes to the iPhone.
//! - `pull UDID DEST`: copies the files named on stdin (one relative path per line) into DEST, under the same paths,
//!   read in blocks and checked for size; `{"done": path, "bytes"}`, `{"skipped": path}` (already there, same size)
//!   or `{"failed": path, "error"}` for each, `{"progress": bytes}` as it goes.
//!
//! The app (`PhoneTransport.swift`) runs it; nothing here writes to the iPhone.

use std::io::Write;
use std::path::{Component, Path, PathBuf};

use idevice::afc::AfcClient;
use idevice::afc::opcode::AfcFopenMode;
use idevice::house_arrest::HouseArrestClient;
use idevice::lockdown::LockdownClient;
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice, UsbmuxdListenEvent};
use idevice::provider::IdeviceProvider;
use idevice::{IdeviceError, IdeviceService};
use serde_json::{Value, json};

/// QLab's bundle identifier: the only app whose folder this reads.
const QLAB: &str = "be.jackfrom.qlab";
/// Bytes read at a time.
const BLOCK: usize = 1 << 20;
const LABEL: &str = "qlick-iphone";

fn say(value: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

/// What an error means for the photographer.
fn state_of(error: &IdeviceError) -> &'static str {
    match error {
        IdeviceError::PasswordProtected => "locked",
        IdeviceError::InvalidHostID
        | IdeviceError::UserDeniedPairing
        | IdeviceError::PairingDialogResponsePending
        | IdeviceError::NotFound => "untrusted",
        _ => "error",
    }
}

fn fail(state: &str, message: String) -> ! {
    say(json!({"error": message, "state": state}));
    std::process::exit(1)
}

fn connection(device: &UsbmuxdDevice) -> &'static str {
    match device.connection_type {
        Connection::Usb => "usb",
        _ => "network",
    }
}

async fn device(udid: &str) -> UsbmuxdDevice {
    let mut mux = UsbmuxdConnection::default().await.unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")));
    mux.get_devices()
        .await
        .unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")))
        .into_iter()
        .find(|d| d.udid == udid)
        .unwrap_or_else(|| fail("gone", "The iPhone isn't plugged in any more.".into()))
}

/// The iPhone's name, through a lockdown session (which needs it to trust this Mac).
async fn name(device: &UsbmuxdDevice) -> Result<String, IdeviceError> {
    let provider = device.to_provider(UsbmuxdAddr::default(), LABEL);
    let mut lockdown = LockdownClient::connect(&provider).await?;
    let pairing = provider.get_pairing_file().await?;
    lockdown.start_session(&pairing).await?;
    let value = lockdown.get_value(Some("DeviceName"), None).await?;
    Ok(value.as_string().unwrap_or("iPhone").to_string())
}

/// QLab's folder on the iPhone.
async fn documents(device: &UsbmuxdDevice) -> Result<AfcClient, IdeviceError> {
    let provider = device.to_provider(UsbmuxdAddr::default(), LABEL);
    let house = HouseArrestClient::connect(&provider).await?;
    house.vend_documents(QLAB).await
}

async fn probe(udid: &str) -> Value {
    let device = device(udid).await;
    let name = match name(&device).await {
        Ok(name) => name,
        Err(e) => return json!({"udid": udid, "state": state_of(&e), "message": e.to_string()}),
    };
    match documents(&device).await {
        Ok(mut afc) => match afc.list_dir("/Documents").await {
            Ok(_) => json!({"udid": udid, "name": name, "state": "ready"}),
            Err(e) => json!({"udid": udid, "name": name, "state": state_of(&e), "message": e.to_string()}),
        },
        // No such app, or one that doesn't share its folder.
        Err(e) => {
            let state = match state_of(&e) {
                "error" => "no_qlab",
                other => other,
            };
            json!({"udid": udid, "name": name, "state": state, "message": e.to_string()})
        }
    }
}

async fn pair(udid: &str) -> Value {
    let device = device(udid).await;
    let provider = device.to_provider(UsbmuxdAddr::default(), LABEL);
    if provider.get_pairing_file().await.is_err() {
        let mut mux = UsbmuxdConnection::default().await.unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")));
        let buid = mux.get_buid().await.unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")));
        let mut lockdown = LockdownClient::connect(&provider).await.unwrap_or_else(|e| fail(state_of(&e), e.to_string()));
        let host = uuid::Uuid::new_v4().to_string().to_uppercase();
        let record = tokio::time::timeout(std::time::Duration::from_secs(90), lockdown.pair(host, buid, Some("Qlick Lab")))
            .await
            .unwrap_or_else(|_| fail("untrusted", "The iPhone wasn't trusted in time.".into()))
            .unwrap_or_else(|e| fail(state_of(&e), e.to_string()));
        let bytes = record.serialize().unwrap_or_else(|e| fail("error", e.to_string()));
        let mut mux = UsbmuxdConnection::default().await.unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")));
        mux.save_pair_record(&device.udid, bytes).await.unwrap_or_else(|e| fail("error", e.to_string()));
    }
    probe(udid).await
}

/// Every file under `dir`, depth first (folders by name, no hidden files).
async fn walk(afc: &mut AfcClient, dir: &str, out: &mut Vec<Value>) -> Result<(), IdeviceError> {
    let mut entries = afc.list_dir(dir).await?;
    entries.sort();
    for entry in entries {
        if entry == "." || entry == ".." || entry.starts_with('.') {
            continue;
        }
        let path = format!("{dir}/{entry}");
        let Ok(info) = afc.get_file_info(&path).await else { continue };
        if info.st_ifmt == "S_IFDIR" {
            Box::pin(walk(afc, &path, out)).await?;
        } else if info.st_ifmt == "S_IFREG" {
            let relative = path.trim_start_matches("/Documents/").to_string();
            out.push(json!({"path": relative, "size": info.size, "modified": info.modified.and_utc().timestamp()}));
        }
    }
    Ok(())
}

/// A relative path that stays inside the folder it's joined to.
fn inside(relative: &str) -> Option<PathBuf> {
    let path = Path::new(relative);
    let fine = !relative.is_empty() && path.components().all(|c| matches!(c, Component::Normal(_)));
    fine.then(|| path.to_path_buf())
}

async fn pull(udid: &str, destination: &Path) {
    let device = device(udid).await;
    let mut afc = documents(&device).await.unwrap_or_else(|e| fail(state_of(&e), e.to_string()));
    let mut wanted = String::new();
    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut wanted);
    for relative in wanted.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let Some(local) = inside(relative).map(|p| destination.join(p)) else {
            say(json!({"failed": relative, "error": "not a path inside QLab's folder"}));
            continue;
        };
        let remote = format!("/Documents/{relative}");
        let size = match afc.get_file_info(&remote).await {
            Ok(info) => info.size,
            Err(e) => {
                say(json!({"failed": relative, "error": e.to_string()}));
                continue;
            }
        };
        if std::fs::metadata(&local).map(|m| m.len() as usize == size).unwrap_or(false) {
            say(json!({"skipped": relative}));
            continue;
        }
        if let Some(folder) = local.parent() {
            if let Err(e) = std::fs::create_dir_all(folder) {
                say(json!({"failed": relative, "error": e.to_string()}));
                continue;
            }
        }
        let part = local.with_file_name(format!(".{}.part", local.file_name().unwrap().to_string_lossy()));
        let result = copy(&mut afc, &remote, &part, size).await;
        match result.and_then(|written| {
            if written != size {
                return Err(format!("{written} bytes read of {size}"));
            }
            std::fs::rename(&part, &local).map(|_| written).map_err(|e| e.to_string())
        }) {
            Ok(bytes) => say(json!({"done": relative, "bytes": bytes})),
            Err(error) => {
                let _ = std::fs::remove_file(&part);
                say(json!({"failed": relative, "error": error}));
            }
        }
    }
}

/// Writes a deletion request for QLab (docs/q-formats.md): a hidden part first, then renamed into place, so QLab
/// never reads half a request.
async fn request_delete(udid: &str) {
    let mut body = Vec::new();
    let _ = std::io::Read::read_to_end(&mut std::io::stdin(), &mut body);
    if serde_json::from_slice::<Value>(&body).map(|v| v["photos"].is_array()).unwrap_or(false) == false {
        fail("error", "not a deletion request".into());
    }
    let device = device(udid).await;
    let mut afc = documents(&device).await.unwrap_or_else(|e| fail(state_of(&e), e.to_string()));
    let folder = "/Documents/.qlab-delete-requests";
    let _ = afc.mk_dir(folder).await;
    let name = uuid::Uuid::new_v4().to_string().to_uppercase();
    let part = format!("{folder}/.{name}.json.part");
    let done = format!("{folder}/{name}.json");
    let written = async {
        let mut file = afc.open(&part, AfcFopenMode::WrOnly).await?;
        let result = file.write_entire(&body).await;
        file.close().await?;
        result
    }
    .await;
    if let Err(e) = written {
        let _ = afc.remove(&part).await;
        fail(state_of(&e), e.to_string());
    }
    if let Err(e) = afc.rename(&part, &done).await {
        let _ = afc.remove(&part).await;
        fail(state_of(&e), e.to_string());
    }
    say(json!({"written": done.trim_start_matches("/Documents/")}));
}

/// Copies one file in blocks; the file on the iPhone is always closed, whatever happens.
async fn copy(afc: &mut AfcClient, remote: &str, local: &Path, size: usize) -> Result<usize, String> {
    let mut out = std::fs::File::create(local).map_err(|e| e.to_string())?;
    let mut file = afc.open(remote, AfcFopenMode::RdOnly).await.map_err(|e| e.to_string())?;
    let mut written = 0usize;
    let mut failure = None;
    while written < size {
        match file.read_n(BLOCK.min(size - written)).await {
            Ok(block) if block.is_empty() => break,
            Ok(block) => {
                if let Err(e) = out.write_all(&block) {
                    failure = Some(e.to_string());
                    break;
                }
                written += block.len();
                say(json!({"progress": block.len()}));
            }
            Err(e) => {
                failure = Some(e.to_string());
                break;
            }
        }
    }
    let closed = file.close().await;
    if let Some(failure) = failure {
        return Err(failure);
    }
    closed.map_err(|e| e.to_string())?;
    out.sync_all().map_err(|e| e.to_string())?;
    Ok(written)
}

async fn watch() {
    use futures::StreamExt;
    let mut mux = UsbmuxdConnection::default().await.unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")));
    for device in mux.get_devices().await.unwrap_or_default() {
        say(json!({"event": "attached", "udid": device.udid, "id": device.device_id, "connection": connection(&device)}));
    }
    let mut listener = UsbmuxdConnection::default().await.unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")));
    let mut events = listener.listen().await.unwrap_or_else(|e| fail("error", format!("usbmuxd: {e}")));
    // Ends when the app closes stdin (or quits).
    let stdin_closed = tokio::task::spawn_blocking(|| {
        let mut sink = String::new();
        while std::io::stdin().read_line(&mut sink).map(|n| n > 0).unwrap_or(false) {
            sink.clear();
        }
    });
    tokio::pin!(stdin_closed);
    loop {
        tokio::select! {
            _ = &mut stdin_closed => break,
            event = events.next() => match event {
                Some(Ok(UsbmuxdListenEvent::Connected(device))) => {
                    say(json!({"event": "attached", "udid": device.udid, "id": device.device_id, "connection": connection(&device)}))
                }
                Some(Ok(UsbmuxdListenEvent::Disconnected(id))) => say(json!({"event": "detached", "id": id})),
                Some(Err(e)) => fail("error", format!("usbmuxd: {e}")),
                None => break,
            },
        }
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("watch") => watch().await,
        Some("probe") if args.len() == 3 => say(probe(&args[2]).await),
        Some("pair") if args.len() == 3 => say(pair(&args[2]).await),
        Some("list") if args.len() == 3 => {
            let device = device(&args[2]).await;
            let mut afc = documents(&device).await.unwrap_or_else(|e| fail(state_of(&e), e.to_string()));
            let mut files = Vec::new();
            if let Err(e) = walk(&mut afc, "/Documents", &mut files).await {
                fail(state_of(&e), e.to_string());
            }
            for file in files {
                say(file);
            }
        }
        Some("pull") if args.len() == 4 => pull(&args[2], Path::new(&args[3])).await,
        Some("request-delete") if args.len() == 3 => request_delete(&args[2]).await,
        _ => fail("error", "usage: qlick-iphone watch | probe UDID | pair UDID | list UDID | pull UDID DEST | request-delete UDID".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_stay_inside_the_folder() {
        assert_eq!(inside("2026-11-15/QLB_0130.DNG"), Some(PathBuf::from("2026-11-15/QLB_0130.DNG")));
        assert_eq!(inside("Recipes/Portra.qrecipe"), Some(PathBuf::from("Recipes/Portra.qrecipe")));
        for bad in ["", "../x", "/etc/passwd", "a/../../b", "./a"] {
            assert_eq!(inside(bad), None, "{bad}");
        }
    }

    #[test]
    fn errors_say_what_to_do() {
        assert_eq!(state_of(&IdeviceError::PasswordProtected), "locked");
        assert_eq!(state_of(&IdeviceError::UserDeniedPairing), "untrusted");
        assert_eq!(state_of(&IdeviceError::InvalidHostID), "untrusted");
    }
}
