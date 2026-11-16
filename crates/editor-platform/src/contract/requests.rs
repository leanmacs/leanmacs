//! The contract of what a window does with what it is asked: the rules
//! every carrier of [`Request`]s keeps, as a check that runs one.
//!
//! A carrier ([`Carries`]) is a window as far as requests go: it carries a
//! request out, and says what it then shows ([`Shown`]). The pure model is
//! [`Shown::carry_out`], which passes the check in this module's tests; a
//! real adapter runs the same check on its translation of a request into
//! what it does, over a window that records what it is told, so that the
//! two cannot drift.
//!
//! Each rule starts from a fresh carrier, which shows a window that is not
//! in fullscreen and not minimised, and has been asked no appearance:
//!
//! - **Entering puts the window in fullscreen**, and entering again leaves
//!   it there: it is not a toggle.
//! - **Leaving takes it out**, and leaving a window not in fullscreen leaves
//!   it out.
//! - **Requests are carried out in the order asked**: entering then leaving
//!   ends windowed, and leaving then entering in fullscreen.
//! - **Minimising a window not in fullscreen minimises it.** What a system
//!   does with a minimise of a window in fullscreen is its own (macOS does
//!   not minimise one), and the contract says nothing of it.
//! - **A title is the window's title**, and of two the last wins.
//! - **An appearance is the window's appearance**, and of two the last
//!   wins.
//! - **A title changes neither fullscreen nor minimised, and fullscreen
//!   changes no title.** An appearance changes neither fullscreen,
//!   minimised nor the title, and they change no appearance.
//! - **Keeping running changes nothing the window shows**: it answers the
//!   system's quit, and is not the window's.
//! - **A menu is the menu bar's, and of two the last wins**, on a carrier
//!   with a menu bar ([`Carries::MENU_BAR`]). **A platform with no menu
//!   bar shows none**, whatever it is asked.
//! - **A menu changes no other thing shown, and they change no menu.**
//!   Neither fullscreen, a title nor an appearance moves the menu shown,
//!   and a menu moves none of them.
//!
//! Whether a request asked with no window running is harmless is the run
//! contract's ([`Check::run`](super::Check::run)): it needs a platform, and
//! this needs only a window.

use std::fmt;

use crate::menu::{Action, Item, Menu, Submenu};
use crate::scripted::Shown;
use crate::{Appearance, Request};

/// A window as far as requests go: what carries a request out, and what it
/// then shows.
pub trait Carries {
    /// Whether the window has a menu bar that shows the menu it is asked
    /// ([`Request::Menu`]). A carrier with none shows no menu, whatever it
    /// is asked.
    const MENU_BAR: bool = true;

    /// Carries out `request`.
    fn carry_out(&mut self, request: Request);

    /// What the window shows now.
    fn shown(&self) -> Shown;
}

/// A rule a carrier broke: what it was asked, from fresh, what it then
/// showed, and the rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestViolation {
    /// The requests carried out, in order, on a fresh carrier.
    pub asked: Vec<Request>,
    /// What it showed after them.
    pub shown: Shown,
    /// The rule it broke, in words.
    pub rule: &'static str,
}

impl fmt::Display for RequestViolation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}: asked {:?}, the window showed {:?}",
            self.rule, self.asked, self.shown
        )
    }
}

/// The rule that a fresh window is neither in fullscreen nor minimised,
/// and has been asked no appearance.
pub const FRESH: &str =
    "a fresh window is neither in fullscreen nor minimised, and has no appearance asked";
/// The rule that entering puts the window in fullscreen, and is no toggle.
pub const ENTERS: &str = "entering puts the window in fullscreen and keeps it there";
/// The rule that leaving takes the window out of fullscreen.
pub const LEAVES: &str = "leaving takes the window out of fullscreen and keeps it out";
/// The rule that requests are carried out in the order asked.
pub const IN_ORDER: &str = "requests are carried out in the order asked";
/// The rule that minimising a window not in fullscreen minimises it.
pub const MINIMISES: &str = "minimising a window not in fullscreen minimises it";
/// The rule that a title is the window's, the last of two winning.
pub const TITLED: &str = "a title is the window's title, and the last wins";
/// The rule that an appearance is the window's, the last of two winning.
pub const APPEARS: &str = "an appearance is the window's appearance, and the last wins";
/// The rule that a title, an appearance and fullscreen leave each other
/// alone.
pub const APART: &str = "a title changes neither fullscreen nor minimised, and fullscreen no title; an appearance changes none of them, and they change no appearance";
/// The rule that keeping running changes nothing the window shows.
pub const KEEPS_RUNNING: &str = "keeping running changes nothing the window shows";
/// The rule that a menu is the menu bar's, the last of two winning.
pub const MENU_SHOWN: &str = "a menu is the menu bar's, and the last wins";
/// The rule that a menu and the other things shown leave each other alone.
pub const MENU_APART: &str = "a menu changes no other thing shown, and they change no menu";
/// The rule that a window with no menu bar shows no menu.
pub const NO_MENU_BAR: &str = "a platform with no menu bar shows none";

/// One rule as the check holds it: the requests carried out on a fresh
/// carrier, what must then hold of what it shows, and the rule's words.
type Rule<'a> = (Vec<Request>, &'a dyn Fn(&Shown) -> bool, &'static str);

/// A menu bar of one menu, titled `title`, with one command item.
fn sample_menu(title: &str) -> Menu {
    Menu {
        menus: vec![Submenu {
            title: title.into(),
            role: None,
            items: vec![Item::Entry {
                title: title.into(),
                key: None,
                action: Action::Command(title.into()),
            }],
        }],
    }
}

/// The request for [`sample_menu`]'s menu titled `title`.
fn menu(title: &str) -> Request {
    Request::Menu(sample_menu(title))
}

/// Holds the carriers `make` gives to the rules, each rule on a fresh one,
/// and gives the first rule broken.
pub fn check<C: Carries>(mut make: impl FnMut() -> C) -> Result<(), RequestViolation> {
    use Request::{EnterFullscreen as Enter, LeaveFullscreen as Leave, Minimise};
    let title = |text: &str| Request::Title(text.into());
    let light = Request::Appearance(Appearance::Light);
    let dark = Request::Appearance(Appearance::Dark);
    let fresh = |shown: &Shown| !shown.fullscreen && !shown.minimised && shown.appearance.is_none();
    fn titled(text: &'static str) -> impl Fn(&Shown) -> bool {
        move |shown| shown.title.as_deref() == Some(text)
    }
    fn appears(appearance: Appearance) -> impl Fn(&Shown) -> bool {
        move |shown| shown.appearance == Some(appearance)
    }
    // What a carrier shows of a menu it was asked last: that menu, or none
    // with no menu bar.
    let showing = |text: &str| C::MENU_BAR.then(|| sample_menu(text));
    let (showing_a, showing_b) = (showing("a"), showing("b"));
    let shows_a = |shown: &Shown| shown.menu == showing_a;
    let shows_b = |shown: &Shown| shown.menu == showing_b;
    let menu_alone =
        |shown: &Shown| fresh(shown) && shown.title.is_none() && shown.menu == showing_a;
    let menu_after = |shown: &Shown| {
        shown.fullscreen
            && !shown.minimised
            && shown.title.as_deref() == Some("a")
            && shows_a(shown)
    };
    let menu_before = |shown: &Shown| shown.fullscreen && titled("a")(shown) && shows_a(shown);
    // An appearance asked before or after a menu moves neither.
    let menu_appears = |shown: &Shown| appears(Appearance::Dark)(shown) && shows_a(shown);
    let menu_rule = if C::MENU_BAR { MENU_SHOWN } else { NO_MENU_BAR };
    let rules: [Rule<'_>; 28] = [
        (vec![], &fresh, FRESH),
        (vec![Enter], &|shown| shown.fullscreen, ENTERS),
        (vec![Enter, Enter], &|shown| shown.fullscreen, ENTERS),
        (vec![Leave], &|shown| !shown.fullscreen, LEAVES),
        (
            vec![Enter, Leave, Leave],
            &|shown| !shown.fullscreen,
            LEAVES,
        ),
        (vec![Enter, Leave], &|shown| !shown.fullscreen, IN_ORDER),
        (vec![Leave, Enter], &|shown| shown.fullscreen, IN_ORDER),
        (vec![Minimise], &|shown| shown.minimised, MINIMISES),
        (vec![title("a")], &titled("a"), TITLED),
        (vec![title("a"), title("b")], &titled("b"), TITLED),
        (vec![title("a")], &fresh, APART),
        (
            vec![Enter, title("a")],
            &|shown| shown.fullscreen && !shown.minimised,
            APART,
        ),
        (vec![title("a"), Enter], &titled("a"), APART),
        (vec![dark.clone()], &appears(Appearance::Dark), APPEARS),
        (
            vec![dark.clone(), light.clone()],
            &appears(Appearance::Light),
            APPEARS,
        ),
        (
            vec![dark.clone()],
            &|shown| !shown.fullscreen && !shown.minimised && shown.title.is_none(),
            APART,
        ),
        (
            vec![Enter, title("a"), dark.clone()],
            &|shown| shown.fullscreen && shown.title.as_deref() == Some("a"),
            APART,
        ),
        (
            vec![dark.clone(), Enter, title("a"), Leave],
            &appears(Appearance::Dark),
            APART,
        ),
        (
            vec![dark.clone(), Minimise],
            &appears(Appearance::Dark),
            APART,
        ),
        (vec![Request::KeepRunning], &fresh, KEEPS_RUNNING),
        (
            vec![Enter, title("a"), Request::KeepRunning],
            &|shown| shown.fullscreen && !shown.minimised && shown.title.as_deref() == Some("a"),
            KEEPS_RUNNING,
        ),
        (vec![menu("a")], &shows_a, menu_rule),
        (vec![menu("a"), menu("b")], &shows_b, menu_rule),
        (vec![menu("a")], &menu_alone, MENU_APART),
        (vec![Enter, title("a"), menu("a")], &menu_after, MENU_APART),
        (vec![menu("a"), Enter, title("a")], &menu_before, MENU_APART),
        (vec![dark.clone(), menu("a")], &menu_appears, MENU_APART),
        (vec![menu("a"), dark], &menu_appears, MENU_APART),
    ];
    for (asked, holds, rule) in rules {
        let mut carrier = make();
        for request in asked.iter().cloned() {
            carrier.carry_out(request);
        }
        let shown = carrier.shown();
        if !holds(&shown) {
            return Err(RequestViolation { asked, shown, rule });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pure model, as a carrier.
    #[derive(Default)]
    struct ScriptedModel(Shown);

    impl Carries for ScriptedModel {
        fn carry_out(&mut self, request: Request) {
            self.0.carry_out(&request);
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn the_request_contract_holds_of_the_scripted_model() {
        assert_eq!(check(ScriptedModel::default), Ok(()));
    }

    /// A window that toggles fullscreen on every enter.
    #[derive(Default)]
    struct Toggles(Shown);

    impl Carries for Toggles {
        fn carry_out(&mut self, request: Request) {
            match request {
                Request::EnterFullscreen => self.0.fullscreen = !self.0.fullscreen,
                other => self.0.carry_out(&other),
            }
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_window_that_toggles_on_enter_is_refused() {
        let refused = check(Toggles::default).expect_err("a toggle is refused");
        assert_eq!(refused.rule, ENTERS);
        assert_eq!(
            refused.asked,
            [Request::EnterFullscreen, Request::EnterFullscreen]
        );
    }

    /// A window that carries each pair of requests out the other way
    /// round: it holds one back until the next comes, and what it shows
    /// counts one held back as carried out.
    #[derive(Default)]
    struct OutOfOrder {
        shown: Shown,
        held: Option<Request>,
    }

    impl Carries for OutOfOrder {
        fn carry_out(&mut self, request: Request) {
            match self.held.take() {
                Some(earlier) => {
                    self.shown.carry_out(&request);
                    self.shown.carry_out(&earlier);
                }
                None => self.held = Some(request),
            }
        }

        fn shown(&self) -> Shown {
            let mut shown = self.shown.clone();
            if let Some(held) = &self.held {
                shown.carry_out(held);
            }
            shown
        }
    }

    #[test]
    fn a_window_that_carries_requests_out_of_order_is_refused() {
        let refused = check(OutOfOrder::default).expect_err("the order is the asker's");
        assert_eq!(refused.rule, IN_ORDER);
    }

    /// A window that keeps the first title it is given.
    #[derive(Default)]
    struct KeepsFirstTitle(Shown);

    impl Carries for KeepsFirstTitle {
        fn carry_out(&mut self, request: Request) {
            if !(matches!(request, Request::Title(_)) && self.0.title.is_some()) {
                self.0.carry_out(&request);
            }
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_window_that_keeps_the_first_title_is_refused() {
        let refused = check(KeepsFirstTitle::default).expect_err("the last title wins");
        assert_eq!(refused.rule, TITLED);
    }

    /// A window whose title takes it out of fullscreen.
    #[derive(Default)]
    struct TitleLeaves(Shown);

    impl Carries for TitleLeaves {
        fn carry_out(&mut self, request: Request) {
            if matches!(request, Request::Title(_)) {
                self.0.fullscreen = false;
            }
            self.0.carry_out(&request);
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_window_whose_title_changes_fullscreen_is_refused() {
        let refused = check(TitleLeaves::default).expect_err("a title leaves fullscreen be");
        assert_eq!(refused.rule, APART);
    }

    /// A window that never minimises.
    #[derive(Default)]
    struct NeverMinimises(Shown);

    impl Carries for NeverMinimises {
        fn carry_out(&mut self, request: Request) {
            if request != Request::Minimise {
                self.0.carry_out(&request);
            }
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_window_that_does_not_minimise_is_refused() {
        let refused = check(NeverMinimises::default).expect_err("a minimise minimises");
        assert_eq!(refused.rule, MINIMISES);
        assert_eq!(refused.asked, [Request::Minimise]);
    }

    /// A window that minimises when it is asked to keep running.
    #[derive(Default)]
    struct KeepRunningMinimises(Shown);

    impl Carries for KeepRunningMinimises {
        fn carry_out(&mut self, request: Request) {
            match request {
                Request::KeepRunning => self.0.minimised = true,
                other => self.0.carry_out(&other),
            }
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_window_that_changes_what_it_shows_on_keep_running_is_refused() {
        let refused =
            check(KeepRunningMinimises::default).expect_err("keeping running changes nothing");
        assert_eq!(refused.rule, KEEPS_RUNNING);
        assert_eq!(refused.asked, [Request::KeepRunning]);
    }

    /// A window that opens in fullscreen.
    struct OpensInFullscreen(Shown);

    impl Carries for OpensInFullscreen {
        fn carry_out(&mut self, request: Request) {
            self.0.carry_out(&request);
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    /// A window that ignores every appearance it is asked.
    #[derive(Default)]
    struct IgnoresAppearance(Shown);

    impl Carries for IgnoresAppearance {
        fn carry_out(&mut self, request: Request) {
            if !matches!(request, Request::Appearance(_)) {
                self.0.carry_out(&request);
            }
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_window_that_ignores_an_appearance_is_refused() {
        let refused = check(IgnoresAppearance::default).expect_err("an appearance is shown");
        assert_eq!(refused.rule, APPEARS);
        assert_eq!(refused.asked, [Request::Appearance(Appearance::Dark)]);
    }

    /// A window whose appearance takes it out of fullscreen.
    #[derive(Default)]
    struct AppearanceLeaves(Shown);

    impl Carries for AppearanceLeaves {
        fn carry_out(&mut self, request: Request) {
            if matches!(request, Request::Appearance(_)) {
                self.0.fullscreen = false;
            }
            self.0.carry_out(&request);
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_window_whose_appearance_changes_fullscreen_is_refused() {
        let refused =
            check(AppearanceLeaves::default).expect_err("an appearance leaves fullscreen be");
        assert_eq!(refused.rule, APART);
    }

    #[test]
    fn a_window_that_is_not_fresh_is_refused() {
        let refused = check(|| {
            OpensInFullscreen(Shown {
                fullscreen: true,
                ..Shown::default()
            })
        })
        .expect_err("the rules start from a fresh window");
        assert_eq!(refused.rule, FRESH);
        assert_eq!(refused.asked, []);
    }

    /// A window that keeps the first menu it is given.
    #[derive(Default)]
    struct KeepsFirstMenu(Shown);

    impl Carries for KeepsFirstMenu {
        fn carry_out(&mut self, request: Request) {
            if !(matches!(request, Request::Menu(_)) && self.0.menu.is_some()) {
                self.0.carry_out(&request);
            }
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_carrier_that_keeps_the_first_menu_is_refused() {
        let refused = check(KeepsFirstMenu::default).expect_err("the last menu wins");
        assert_eq!(refused.rule, MENU_SHOWN);
    }

    /// A window whose menu takes it out of fullscreen.
    #[derive(Default)]
    struct MenuLeaves(Shown);

    impl Carries for MenuLeaves {
        fn carry_out(&mut self, request: Request) {
            if matches!(request, Request::Menu(_)) {
                self.0.fullscreen = false;
            }
            self.0.carry_out(&request);
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_carrier_whose_menu_takes_it_out_of_fullscreen_is_refused() {
        let refused = check(MenuLeaves::default).expect_err("a menu leaves fullscreen be");
        assert_eq!(refused.rule, MENU_APART);
    }

    /// A window whose menu forgets the appearance it was asked.
    #[derive(Default)]
    struct MenuForgetsAppearance(Shown);

    impl Carries for MenuForgetsAppearance {
        fn carry_out(&mut self, request: Request) {
            if matches!(request, Request::Menu(_)) {
                self.0.appearance = None;
            }
            self.0.carry_out(&request);
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_carrier_whose_menu_forgets_the_appearance_is_refused() {
        let refused =
            check(MenuForgetsAppearance::default).expect_err("a menu leaves the appearance be");
        assert_eq!(refused.rule, MENU_APART);
        assert_eq!(
            refused.asked,
            [Request::Appearance(Appearance::Dark), menu("a")]
        );
    }

    /// A window with no menu bar that shows the menus it is asked all the
    /// same.
    #[derive(Default)]
    struct NoBarShowsMenus(Shown);

    impl Carries for NoBarShowsMenus {
        const MENU_BAR: bool = false;

        fn carry_out(&mut self, request: Request) {
            self.0.carry_out(&request);
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_carrier_with_no_menu_bar_that_shows_a_menu_is_refused() {
        let refused = check(NoBarShowsMenus::default).expect_err("no menu bar shows no menu");
        assert_eq!(refused.rule, NO_MENU_BAR);
    }

    /// A window with no menu bar: a menu changes nothing it shows.
    #[derive(Default)]
    struct NoBar(Shown);

    impl Carries for NoBar {
        const MENU_BAR: bool = false;

        fn carry_out(&mut self, request: Request) {
            if !matches!(request, Request::Menu(_)) {
                self.0.carry_out(&request);
            }
        }

        fn shown(&self) -> Shown {
            self.0.clone()
        }
    }

    #[test]
    fn a_carrier_with_no_menu_bar_that_shows_none_passes() {
        assert_eq!(check(NoBar::default), Ok(()));
    }

    #[test]
    fn a_violation_says_its_rule_what_was_asked_and_what_was_shown() {
        let violation = RequestViolation {
            asked: vec![Request::Minimise],
            shown: Shown::default(),
            rule: MINIMISES,
        };
        let said = violation.to_string();
        assert!(said.starts_with(MINIMISES), "{said}");
        assert!(said.contains("Minimise"), "{said}");
    }
}
