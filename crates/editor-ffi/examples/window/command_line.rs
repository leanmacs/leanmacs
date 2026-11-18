//! What the command line asks for: how long the window stays, whether a
//! picture is read and whether one is required, and the family the fixture
//! is laid out in.

use std::time::Duration;

/// What the command line asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    /// How long the window stays once it is ready, if nobody closes it;
    /// `None` when it stays until a person closes it.
    pub stay: Option<Duration>,
    /// Whether every frame's picture must be compared for the run to pass.
    pub require_picture: bool,
    /// Whether each frame's picture is read back and compared at all.
    pub read_picture: bool,
    /// The family of the machine's fonts the fixture is laid out in;
    /// `None` for the fixture fonts.
    pub family: Option<String>,
}

/// The options `arguments` ask for; `None` when they are not understood.
/// Two pairs contradict each other and are not understood together: a
/// time to stay (`--seconds`) with staying until closed
/// (`--until-closed`), and a picture required (`--require-picture`) with
/// none read (`--no-picture`). A family is a name: not nothing, and not
/// another option.
pub fn options(arguments: &[&str]) -> Option<Options> {
    let mut options = Options {
        stay: Some(Duration::from_secs(20)),
        require_picture: false,
        read_picture: true,
        family: None,
    };
    // Whether a time to stay was given, and whether staying was.
    let (mut timed, mut until_closed) = (false, false);
    let mut rest = arguments;
    loop {
        rest = match rest {
            [] => break,
            ["--seconds", seconds, rest @ ..] => {
                options.stay = Some(Duration::from_secs(seconds.parse().ok()?));
                timed = true;
                rest
            }
            ["--require-picture", rest @ ..] => {
                options.require_picture = true;
                rest
            }
            ["--until-closed", rest @ ..] => {
                until_closed = true;
                rest
            }
            ["--no-picture", rest @ ..] => {
                options.read_picture = false;
                rest
            }
            ["--family", name, rest @ ..] if !name.is_empty() && !name.starts_with("--") => {
                options.family = Some((*name).to_owned());
                rest
            }
            _ => return None,
        };
    }
    if until_closed {
        options.stay = None;
    }
    let contradicts = (timed && until_closed) || (options.require_picture && !options.read_picture);
    (!contradicts).then_some(options)
}

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{Options, options};

    /// What a command line with none of the options asks for: twenty
    /// seconds, pictures read and compared where the surface gives one, in
    /// the fixture fonts.
    fn as_it_comes() -> Options {
        Options {
            stay: Some(Duration::from_secs(20)),
            require_picture: false,
            read_picture: true,
            family: None,
        }
    }

    #[test]
    fn the_command_line_says_how_long_the_window_stays_and_whether_a_picture_is_required() {
        let asked = |stay, require_picture| {
            Some(Options {
                stay: Some(Duration::from_secs(stay)),
                require_picture,
                ..as_it_comes()
            })
        };
        assert_eq!(options(&[]), asked(20, false));
        assert_eq!(options(&["--seconds", "6"]), asked(6, false));
        assert_eq!(options(&["--require-picture"]), asked(20, true));
        // In either order.
        assert_eq!(
            options(&["--seconds", "6", "--require-picture"]),
            asked(6, true)
        );
        assert_eq!(
            options(&["--require-picture", "--seconds", "6"]),
            asked(6, true)
        );
    }

    #[test]
    fn the_command_line_says_whether_the_window_stays_whether_pictures_are_read_and_in_which_family()
     {
        // Until a person closes it.
        assert_eq!(
            options(&["--until-closed"]),
            Some(Options {
                stay: None,
                ..as_it_comes()
            })
        );
        // No picture is read back.
        assert_eq!(
            options(&["--no-picture"]),
            Some(Options {
                read_picture: false,
                ..as_it_comes()
            })
        );
        // In a family of the machine's fonts, whose name may be several
        // words.
        assert_eq!(
            options(&["--family", "Menlo"]),
            Some(Options {
                family: Some("Menlo".to_owned()),
                ..as_it_comes()
            })
        );
        assert_eq!(
            options(&["--family", "Helvetica Neue"]).and_then(|options| options.family),
            Some("Helvetica Neue".to_owned())
        );
        // All three, as a person runs it by hand, in any order.
        let by_hand = Some(Options {
            stay: None,
            require_picture: false,
            read_picture: false,
            family: Some("Menlo".to_owned()),
        });
        assert_eq!(
            options(&["--until-closed", "--no-picture", "--family", "Menlo"]),
            by_hand
        );
        assert_eq!(
            options(&["--family", "Menlo", "--no-picture", "--until-closed"]),
            by_hand
        );
        // Each with what it does not contradict.
        assert_eq!(
            options(&["--seconds", "2", "--no-picture"]),
            Some(Options {
                stay: Some(Duration::from_secs(2)),
                read_picture: false,
                ..as_it_comes()
            })
        );
        assert_eq!(
            options(&["--until-closed", "--require-picture"]),
            Some(Options {
                stay: None,
                require_picture: true,
                ..as_it_comes()
            })
        );
    }

    #[test]
    fn options_that_contradict_each_other_are_not_understood() {
        for arguments in [
            // A window cannot both close after a time and stay.
            &["--until-closed", "--seconds", "6"][..],
            &["--seconds", "6", "--until-closed"],
            // A picture cannot be required and not read.
            &["--no-picture", "--require-picture"],
            &["--require-picture", "--no-picture"],
            &["--until-closed", "--no-picture", "--require-picture"],
        ] {
            assert_eq!(options(arguments), None, "{arguments:?}");
        }
    }

    #[test]
    fn a_command_line_that_is_not_understood_gives_no_options() {
        for arguments in [
            &["--seconds"][..],
            &["--seconds", "soon"],
            &["--seconds", "--require-picture"],
            &["--require-pictures"],
            &["6"],
            // A family is a name, and a name is not an option or nothing.
            &["--family"],
            &["--family", ""],
            &["--family", "--no-picture"],
            &["--no-pictures"],
            &["--until-close"],
        ] {
            assert_eq!(options(arguments), None, "{arguments:?}");
        }
    }
}
