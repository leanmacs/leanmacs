//! The permission requests a session has parked, under the tickets Lean
//! answers them by: the protocol model's rules (`agents-api`'s
//! `AgentsApiTest/Protocol.lean`) kept by the crate.
//!
//! - **A request is parked under a fresh ticket** in the current turn
//!   ([`Tickets::ask`]), unless that turn is cancelled: then it is handed
//!   back to be answered `cancelled` at once, and never parked.
//! - **A ticket is answered once** ([`Tickets::answer`]): it is taken out
//!   as it is answered, so a second answer, or an answer to a ticket never
//!   asked, finds nothing.
//! - **A cancel answers every parked request of the current turn**
//!   ([`Tickets::cancel`]) and marks the turn cancelled, so none of that
//!   turn is pending afterwards, a request that arrives after the cancel
//!   included.
//! - **The close answers every parked request** ([`Tickets::close`]), as a
//!   dropped responder does.
//!
//! It is generic over what a parked request holds (`R`, the SDK's responder
//! in the session), so its tests hold plain values.

/// Where [`Tickets::ask`] put a request.
#[derive(Debug, PartialEq, Eq)]
pub enum Asked<R> {
    /// Parked under the ticket, in the turn.
    Parked {
        /// The ticket.
        ticket: u64,
        /// The turn; none before the first prompt.
        turn: Option<u64>,
    },
    /// Its turn is cancelled: answer it `cancelled` now. Its ticket is
    /// spent.
    Cancelled {
        /// The ticket.
        ticket: u64,
        /// The request, handed back.
        request: R,
    },
}

/// The parked permission requests of a session.
#[derive(Debug)]
pub struct Tickets<R> {
    /// The next ticket.
    next: u64,
    /// The parked requests, oldest first: each with its ticket and turn.
    parked: Vec<(u64, Option<u64>, R)>,
    /// The current turn.
    turn: Option<u64>,
    /// The turns cancelled.
    cancelled: Vec<u64>,
}

impl<R> Default for Tickets<R> {
    fn default() -> Self {
        Self {
            next: 1,
            parked: Vec::new(),
            turn: None,
            cancelled: Vec::new(),
        }
    }
}

impl<R> Tickets<R> {
    /// None parked, before the first turn.
    pub fn new() -> Self {
        Self::default()
    }

    /// Begins the turn `turn`: a request asked from now is parked in it.
    pub fn begin(&mut self, turn: u64) {
        self.turn = Some(turn);
    }

    /// The current turn.
    pub fn turn(&self) -> Option<u64> {
        self.turn
    }

    /// Whether the current turn is cancelled.
    fn turn_cancelled(&self) -> bool {
        self.turn.is_some_and(|turn| self.cancelled.contains(&turn))
    }

    /// Parks `request` under a fresh ticket in the current turn, or hands it
    /// back to be answered `cancelled` when that turn is cancelled.
    pub fn ask(&mut self, request: R) -> Asked<R> {
        let ticket = self.next;
        self.next += 1;
        if self.turn_cancelled() {
            Asked::Cancelled { ticket, request }
        } else {
            self.parked.push((ticket, self.turn, request));
            Asked::Parked {
                ticket,
                turn: self.turn,
            }
        }
    }

    /// Takes out the parked request of `ticket`, to be answered; `None` for
    /// a ticket not parked: answered already, withdrawn, or never asked.
    pub fn answer(&mut self, ticket: u64) -> Option<R> {
        let index = self.parked.iter().position(|(held, ..)| *held == ticket)?;
        Some(self.parked.remove(index).2)
    }

    /// Cancels the current turn: takes out every parked request of it, each
    /// with its ticket, to be answered `cancelled`, oldest first, and marks
    /// the turn cancelled. Before the first turn it takes out nothing.
    pub fn cancel(&mut self) -> Vec<(u64, R)> {
        let Some(turn) = self.turn else {
            return Vec::new();
        };
        if !self.cancelled.contains(&turn) {
            self.cancelled.push(turn);
        }
        let (withdrawn, kept) = std::mem::take(&mut self.parked)
            .into_iter()
            .partition(|(_, held, _)| *held == Some(turn));
        self.parked = kept;
        withdrawn
            .into_iter()
            .map(|(ticket, _, request)| (ticket, request))
            .collect()
    }

    /// Takes out every parked request, each with its ticket, oldest first.
    pub fn close(&mut self) -> Vec<(u64, R)> {
        std::mem::take(&mut self.parked)
            .into_iter()
            .map(|(ticket, _, request)| (ticket, request))
            .collect()
    }

    /// The tickets parked, oldest first.
    pub fn parked(&self) -> Vec<u64> {
        self.parked.iter().map(|(ticket, ..)| *ticket).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_ticket_is_answered_once_and_a_ticket_never_asked_is_answered_never() {
        let mut tickets = Tickets::new();
        tickets.begin(1);
        assert_eq!(
            tickets.ask("first"),
            Asked::Parked {
                ticket: 1,
                turn: Some(1)
            }
        );
        assert_eq!(tickets.answer(1), Some("first"));
        assert_eq!(tickets.answer(1), None, "a second answer finds nothing");
        assert_eq!(tickets.answer(7), None, "nor does a ticket never asked");
    }

    #[test]
    fn a_cancel_answers_every_parked_request_of_the_current_turn_and_leaves_another_turn_s() {
        let mut tickets = Tickets::new();
        tickets.begin(1);
        tickets.ask("one");
        tickets.begin(2);
        tickets.ask("two");
        tickets.ask("three");
        assert_eq!(tickets.cancel(), vec![(2, "two"), (3, "three")]);
        assert_eq!(tickets.parked(), vec![1]);
        assert_eq!(
            tickets.answer(2),
            None,
            "a withdrawn ticket is not answerable"
        );
    }

    #[test]
    fn a_request_that_arrives_after_its_turn_s_cancel_is_handed_back_at_once_and_never_parked() {
        let mut tickets = Tickets::new();
        tickets.begin(1);
        tickets.ask("parked");
        assert_eq!(tickets.cancel(), vec![(1, "parked")]);
        assert_eq!(
            tickets.ask("late"),
            Asked::Cancelled {
                ticket: 2,
                request: "late"
            }
        );
        assert!(tickets.parked().is_empty(), "none of the turn is pending");
        tickets.begin(2);
        assert_eq!(
            tickets.ask("next turn"),
            Asked::Parked {
                ticket: 3,
                turn: Some(2)
            },
            "a later turn parks again"
        );
    }

    #[test]
    fn the_close_answers_every_parked_request_and_a_cancel_before_any_turn_answers_none() {
        let mut tickets = Tickets::new();
        tickets.ask("before");
        assert_eq!(tickets.cancel(), vec![], "no turn to cancel");
        tickets.begin(1);
        tickets.ask("during");
        assert_eq!(tickets.close(), vec![(1, "before"), (2, "during")]);
        assert!(tickets.parked().is_empty());
    }
}
