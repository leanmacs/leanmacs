//! The published fake of the [`Renderer`] port: [`RecordingRenderer`].
//!
//! It draws nothing. It keeps every request it is given, and answers as a
//! renderer that keeps its rows by their content hashes does: the rows it
//! says it built and reused are a [`RowCache`]'s. Its glyph counts are
//! always 0.
//!
//! A test can tell it to fail its next present
//! ([`RecordingRenderer::fail_next_present`]): that draw is recorded,
//! builds nothing and answers `presented: false`. And a test can give it a
//! [`FakeClock`] to move on by a stated time in each draw
//! ([`RecordingRenderer::taking`]), so a draw takes time on the clock the
//! render loop reads.

use std::sync::Arc;

use editor_layout::frame::Frame;

use crate::clock::FakeClock;
use crate::port::{DrawRequest, Drawn, Renderer, Target};
use crate::rows::RowCache;

/// One request a [`RecordingRenderer`] was given.
#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    /// The frame.
    pub frame: Arc<Frame>,
    /// The target.
    pub target: Target,
}

/// The fake renderer: records what it is asked to draw.
#[derive(Debug, Default)]
pub struct RecordingRenderer {
    /// Every request, in order.
    requests: Vec<Request>,
    /// The rows it would keep.
    rows: RowCache<()>,
    /// Whether the next draw fails to present.
    fail_next: bool,
    /// The clock a draw moves on, and by how far.
    clock: Option<(FakeClock, u64)>,
}

impl RecordingRenderer {
    /// A renderer that has been asked for nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// This renderer, with each of its draws moving `clock` on by `ns`
    /// nanoseconds, whether or not it presents.
    #[must_use]
    pub fn taking(mut self, clock: FakeClock, ns: u64) -> Self {
        self.clock = Some((clock, ns));
        self
    }

    /// Makes the next draw fail to present: it is recorded, builds nothing
    /// and answers `presented: false`. The draw after it presents.
    pub fn fail_next_present(&mut self) {
        self.fail_next = true;
    }

    /// Every request it was given, in order.
    pub fn requests(&self) -> &[Request] {
        &self.requests
    }
}

impl Renderer for RecordingRenderer {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        self.requests.push(Request {
            frame: Arc::clone(request.frame),
            target: request.target,
        });
        if let Some((clock, ns)) = &self.clock {
            clock.advance(*ns);
        }
        if std::mem::take(&mut self.fail_next) {
            return Drawn::default();
        }
        let reuse = self
            .rows
            .update(request.frame, request.target.scale, |_| ());
        Drawn {
            presented: true,
            rows_rebuilt: reuse.rebuilt,
            rows_reused: reuse.reused,
            ..Drawn::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use editor_layout::Layout;
    use editor_layout::frame::Frame;
    use editor_layout::scene::{Rect, Scene};
    use editor_layout::shaper::fake::CellShaper;

    use super::{RecordingRenderer, Request};
    use crate::clock::{Clock, FakeClock};
    use crate::port::{DrawRequest, Drawn, Renderer, Target};
    use crate::rows::shown;

    /// A target of 400 by 400 pixels at `scale`.
    fn target(scale: f32) -> Target {
        Target {
            width: 400,
            height: 400,
            scale,
        }
    }

    /// The frame of `text` in one view, laid out on the fake shaper.
    fn frame_of(text: &str) -> Arc<Frame> {
        let rect = Rect {
            x: 0,
            y: 0,
            width: 400,
            height: 400,
        };
        Arc::new(Layout::new(CellShaper::new(10.0, 16.0)).frame(&Scene::of_text(text, rect)))
    }

    /// How many rows `frame` shows.
    fn rows(frame: &Frame) -> u64 {
        shown(frame).count() as u64
    }

    #[test]
    fn it_keeps_every_request_it_is_given() {
        let mut renderer = RecordingRenderer::new();
        assert!(renderer.requests().is_empty());
        let (first, second) = (frame_of("one"), frame_of("two"));
        renderer.draw(&DrawRequest {
            frame: &first,
            target: target(1.0),
        });
        renderer.draw(&DrawRequest {
            frame: &second,
            target: target(2.0),
        });
        assert_eq!(
            renderer.requests(),
            [
                Request {
                    frame: Arc::clone(&first),
                    target: target(1.0)
                },
                Request {
                    frame: Arc::clone(&second),
                    target: target(2.0)
                },
            ]
        );
        // The frame it keeps is the one it was handed, not a copy.
        assert!(Arc::ptr_eq(&renderer.requests()[0].frame, &first));
    }

    #[test]
    fn it_answers_with_the_rows_a_row_cache_builds_and_reuses() {
        let mut renderer = RecordingRenderer::new();
        let frame = frame_of("one\ntwo\nthree");
        let request = DrawRequest {
            frame: &frame,
            target: target(1.0),
        };
        let all = rows(&frame);
        let first = renderer.draw(&request);
        assert_eq!(
            first,
            Drawn {
                presented: true,
                rows_rebuilt: all,
                ..Drawn::default()
            }
        );
        let again = renderer.draw(&request);
        assert_eq!(
            again,
            Drawn {
                presented: true,
                rows_reused: all,
                ..Drawn::default()
            }
        );
        // Another scale is another set of rows.
        let scaled = renderer.draw(&DrawRequest {
            frame: &frame,
            target: target(2.0),
        });
        assert_eq!((scaled.rows_rebuilt, scaled.rows_reused), (all, 0));
    }

    #[test]
    fn a_present_it_was_told_to_fail_is_recorded_builds_nothing_and_fails_once() {
        let mut renderer = RecordingRenderer::new();
        let frame = frame_of("one\ntwo");
        let request = DrawRequest {
            frame: &frame,
            target: target(1.0),
        };
        renderer.fail_next_present();
        assert_eq!(renderer.draw(&request), Drawn::default());
        assert_eq!(renderer.requests().len(), 1);
        // The next draw presents, and builds what the failed one did not.
        let next = renderer.draw(&request);
        assert!(next.presented);
        assert_eq!((next.rows_rebuilt, next.rows_reused), (rows(&frame), 0));
        assert_eq!(renderer.requests().len(), 2);
    }

    #[test]
    fn each_draw_moves_the_clock_it_was_given() {
        let clock = FakeClock::new();
        let mut renderer = RecordingRenderer::new().taking(clock.clone(), 250);
        let frame = frame_of("one");
        let request = DrawRequest {
            frame: &frame,
            target: target(1.0),
        };
        renderer.draw(&request);
        assert_eq!(clock.now_ns(), 251);
        // A draw that fails to present takes its time too.
        renderer.fail_next_present();
        renderer.draw(&request);
        assert_eq!(clock.now_ns(), 501);
    }
}
