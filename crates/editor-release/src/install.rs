//! What a user does after downloading the image: get past Gatekeeper on
//! the first launch, and see which build is installed.
//!
//! The words are `packaging/macos/README.txt`'s, the README in the image,
//! word for word, and a test holds them to it. They are kept here once, as
//! plain text: the download page ([`site`](crate::site)) renders them as
//! HTML and the release notes ([`nightly::notes`](crate::nightly::notes))
//! as Markdown, each renderer adding only its own markup, so the page, the
//! notes and the README say the same thing.

/// Why the first launch needs steps.
pub const FIRST_LAUNCH_WHY: &str = "The app is ad-hoc signed and not notarized, so macOS blocks it the first time. Since macOS 15, Control-click > Open no longer gets past this. Instead:";

/// The first-launch steps, in the README's order.
pub const FIRST_LAUNCH: [&str; 3] = [
    "Open Leanmacs once. macOS says it cannot check it; click Done.",
    "Open System Settings > Privacy & Security, scroll down, and click \"Open Anyway\" beside the message about Leanmacs.",
    "Open Leanmacs again and confirm.",
];

/// The fallback's introduction.
pub const QUARANTINE_WHY: &str = "If that does not work, remove the quarantine flag in Terminal:";

/// The fallback's command.
pub const QUARANTINE_FIX: &str = "xattr -dr com.apple.quarantine /Applications/Leanmacs.app";

/// The command that prints the installed build.
pub const VERSION_COMMAND: &str = "/Applications/Leanmacs.app/Contents/MacOS/editor --version";

/// What [`VERSION_COMMAND`] prints.
pub const VERSION_PRINTS: &str = "prints the version, the build ID, the commit and the core's tag.";

#[cfg(test)]
mod tests {
    use super::*;

    const README: &str = include_str!("../../../packaging/macos/README.txt");

    /// `text` with every run of whitespace made one space.
    fn collapsed(text: &str) -> String {
        text.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn the_install_text_is_the_readmes() {
        let readme = collapsed(README);
        for (n, step) in FIRST_LAUNCH.iter().enumerate() {
            let numbered = format!("{}. {}", n + 1, collapsed(step));
            assert!(readme.contains(&numbered), "README.txt lacks {numbered}");
        }
        for line in [
            FIRST_LAUNCH_WHY,
            QUARANTINE_WHY,
            QUARANTINE_FIX,
            VERSION_COMMAND,
        ] {
            assert!(readme.contains(&collapsed(line)), "README.txt lacks {line}");
        }
        // The README says it as "It prints the version, the build ID (...),
        // the commit and the core's tag (...)."
        assert!(readme.contains("It prints the version, the build ID ("));
        assert!(readme.contains("), the commit and the core's tag ("));
    }
}
