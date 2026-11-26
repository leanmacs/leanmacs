//! The command line: `config-migrate [<config dir>]`.
//!
//! No argument converts `$XDG_CONFIG_HOME/leanmacs`, or
//! `$HOME/.config/leanmacs` when that variable is unset or empty: the
//! directory the editor's window mode loads. One argument is the
//! directory. Two arguments, or one starting with `-`, is the usage. The
//! binary reads the two variables at its edge and passes them in as data.

use std::ffi::OsString;
use std::path::PathBuf;

/// A command line [`parse`] does not take.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandError {
    /// The usage: more than one argument, or an option.
    Usage,
    /// No directory was named, and neither `XDG_CONFIG_HOME` nor `HOME` is
    /// set to give the default.
    NoHome,
}

/// The usage, as the binary prints it.
pub const USAGE: &str = "usage: config-migrate [<config dir>]\n  converts a config of .lean files in byte order, with no header, to init.lean and Config/<Name>.lean\n  the config dir defaults to ${XDG_CONFIG_HOME:-$HOME/.config}/leanmacs\n  the file that defines setup, and the files after it, become init.lean; the files before it become Config/<Name>.lean";

/// What [`CommandError::NoHome`] says.
pub const NO_HOME: &str =
    "neither XDG_CONFIG_HOME nor HOME is set, so there is no default config directory: name one";

/// The directory to convert, as the user gave it or as the default spells
/// it, from the arguments (the program's name left out) and the values of
/// `XDG_CONFIG_HOME` and `HOME`.
///
/// # Errors
///
/// [`CommandError`], as above.
pub fn parse(
    args: &[OsString],
    xdg_config_home: Option<OsString>,
    home: Option<OsString>,
) -> Result<PathBuf, CommandError> {
    match args {
        [dir] if dir.as_encoded_bytes().starts_with(b"-") => Err(CommandError::Usage),
        [dir] => Ok(PathBuf::from(dir)),
        [] => {
            let mut dir = match (xdg_config_home, home) {
                (Some(config), _) if !config.is_empty() => config,
                (_, Some(mut home)) => {
                    home.push("/.config");
                    home
                }
                (_, None) => return Err(CommandError::NoHome),
            };
            dir.push("/leanmacs");
            Ok(PathBuf::from(dir))
        }
        _ => Err(CommandError::Usage),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<OsString> {
        words.iter().map(OsString::from).collect()
    }

    #[test]
    fn the_default_directory_is_under_xdg_config_home_else_home_dot_config() {
        assert_eq!(
            parse(&[], Some("/x".into()), Some("/home/u".into())),
            Ok(PathBuf::from("/x/leanmacs"))
        );
        assert_eq!(
            parse(&[], Some("".into()), Some("/home/u".into())),
            Ok(PathBuf::from("/home/u/.config/leanmacs"))
        );
        assert_eq!(
            parse(&[], None, Some("/home/u".into())),
            Ok(PathBuf::from("/home/u/.config/leanmacs"))
        );
        assert_eq!(parse(&[], None, None), Err(CommandError::NoHome));
        assert_eq!(
            parse(&args(&["conf"]), None, None),
            Ok(PathBuf::from("conf"))
        );
    }

    #[test]
    fn two_arguments_or_an_option_is_the_usage() {
        assert_eq!(
            parse(&args(&["a", "b"]), None, Some("/h".into())),
            Err(CommandError::Usage)
        );
        assert_eq!(
            parse(&args(&["--help"]), None, Some("/h".into())),
            Err(CommandError::Usage)
        );
        assert_eq!(
            parse(&args(&["-"]), None, Some("/h".into())),
            Err(CommandError::Usage)
        );
    }
}
