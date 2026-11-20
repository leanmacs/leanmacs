//! Whether text is smoothed: the user's `AppleFontSmoothing`, read
//! through a port.
//!
//! macOS stores the preference as an integer, from 0 to 3, in the user's
//! global domain; the system smooths unless it is 0. Zed and crossfont
//! read it the same way. The port ([`FontDefaults`]) says what the
//! preference holds, and [`smoothing`] decides, so the decision is tested
//! on the fake ([`fake::Canned`]) and no test reads this machine's
//! preferences. The real adapter is `SystemDefaults`, on macOS.

/// What `AppleFontSmoothing` holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Preference {
    /// Nothing: the key is not set.
    Missing,
    /// An integer.
    Integer(i64),
    /// Something that is not an integer, a boolean or a string.
    Other,
}

/// The port: what the system's font defaults hold.
pub trait FontDefaults {
    /// What `AppleFontSmoothing` holds for this application, or else
    /// globally.
    fn font_smoothing(&self) -> Preference;
}

/// Whether text is smoothed, given the preference: only an integer 0
/// turns smoothing off.
pub fn smoothing(preference: Preference) -> bool {
    preference != Preference::Integer(0)
}

/// The port's published fake.
pub mod fake {
    use super::{FontDefaults, Preference};

    /// Font defaults that hold one preference, given.
    #[derive(Debug, Clone, Copy)]
    pub struct Canned(pub Preference);

    impl FontDefaults for Canned {
        fn font_smoothing(&self) -> Preference {
            self.0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::Canned;
    use super::{FontDefaults, Preference, smoothing};

    /// Whether text is smoothed under `defaults`.
    fn smooths(defaults: &impl FontDefaults) -> bool {
        smoothing(defaults.font_smoothing())
    }

    #[test]
    fn text_is_smoothed_when_the_preference_is_not_set() {
        assert!(smooths(&Canned(Preference::Missing)));
    }

    #[test]
    fn a_preference_of_zero_turns_smoothing_off() {
        assert!(!smooths(&Canned(Preference::Integer(0))));
    }

    #[test]
    fn every_other_integer_smooths() {
        for level in [1, 2, 3, -1, 4] {
            assert!(smooths(&Canned(Preference::Integer(level))), "{level}");
        }
    }

    #[test]
    fn a_preference_that_is_not_an_integer_smooths() {
        // A boolean false, written with `defaults write -g
        // AppleFontSmoothing -bool false`, is no integer 0, so it smooths,
        // as Zed's and crossfont's readings do.
        assert!(smooths(&Canned(Preference::Other)));
    }
}
