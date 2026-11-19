//! Reads the shipped data files (profiles, spectral LUTs, filter databases).
//!
//! They come from disk; reads go through here so there is one place to change
//! where they come from.
use std::io;
use std::path::Path;

pub fn read(path: &Path) -> io::Result<Vec<u8>> {
    std::fs::read(path)
}

/// Whether `path` is a readable file.
pub fn is_file(path: &Path) -> bool {
    path.is_file()
}

pub fn read_to_string(path: &Path) -> io::Result<String> {
    String::from_utf8(read(path)?).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}
