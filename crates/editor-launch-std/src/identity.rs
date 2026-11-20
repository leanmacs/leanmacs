//! CoreFoundation's main bundle, as this process sees it: the path of the
//! bundle `CFBundleGetMainBundle` answers, and its `CFBundleIdentifier`.
//!
//! On macOS this is what `NSBundle.mainBundle`, AppKit's app name and
//! LaunchServices' check-in are built on, and what the launcher's
//! `CFProcessPath` points at the app (`docs/design/lean-runtime.md`, "The
//! app's identity across an exec"). A process outside any bundle has the
//! directory of its executable as its main bundle, with no identifier.
//! Elsewhere there is no main bundle.

use std::path::PathBuf;

/// The main bundle's path and identifier; `None` where there is no
/// CoreFoundation.
#[cfg(target_os = "macos")]
#[must_use]
pub fn main_bundle() -> Option<(PathBuf, Option<String>)> {
    use objc2_core_foundation::CFBundle;
    let bundle = CFBundle::main_bundle()?;
    let path = bundle.bundle_url()?.to_file_path()?;
    let identifier = bundle.identifier().map(|id| id.to_string());
    Some((path, identifier))
}

/// The main bundle's path and identifier; `None` where there is no
/// CoreFoundation.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn main_bundle() -> Option<(PathBuf, Option<String>)> {
    None
}

/// The line `--probe` and `launch-probe` print for it: `bundle <path>
/// identifier <id>`, `bundle <path> identifier none`, or `bundle none`.
#[must_use]
pub fn line(main: Option<&(PathBuf, Option<String>)>) -> String {
    match main {
        Some((path, id)) => format!(
            "bundle {} identifier {}",
            path.display(),
            id.as_deref().unwrap_or("none")
        ),
        None => "bundle none".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_line_names_the_bundle_and_identifier_or_none() {
        assert_eq!(
            line(Some(&("/A.app".into(), Some("org.x".into())))),
            "bundle /A.app identifier org.x"
        );
        assert_eq!(
            line(Some(&("/bin".into(), None))),
            "bundle /bin identifier none"
        );
        assert_eq!(line(None), "bundle none");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_test_outside_any_bundle_has_a_main_bundle_with_no_identifier() {
        let (_, identifier) = main_bundle().expect("macOS always has a main bundle");
        assert_eq!(identifier, None);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn elsewhere_there_is_no_main_bundle() {
        assert_eq!(main_bundle(), None);
    }
}
