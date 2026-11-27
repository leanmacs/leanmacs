//! What the tests share: `editor-service`'s stream values, converted to
//! the wrapper's mirror of them (`editor_package::frame`, `editor_package::stream`). Each
//! conversion matches every variant on purpose, as the wire's encoder
//! does: a new way to end, to frame or to refuse must be mirrored in the
//! wrapper, or this stops compiling.

use editor_package::frame as wrapper_frame;
use editor_package::stream as wrapper;
use editor_service::frame;
use editor_service::stream;

/// `stream`, as the wrapper's.
pub const fn stream_of(stream: frame::Stream) -> wrapper_frame::Stream {
    match stream {
        frame::Stream::Out => wrapper_frame::Stream::Out,
        frame::Stream::Err => wrapper_frame::Stream::Err,
    }
}

/// `frames`, as the wrapper's.
pub fn frames(frames: frame::Frames) -> wrapper_frame::Frames {
    match frames {
        frame::Frames::Lines(lines) => wrapper_frame::Frames::Lines(lines),
        frame::Frames::Bytes(bytes) => wrapper_frame::Frames::Bytes(bytes),
        frame::Frames::Messages(bodies) => wrapper_frame::Frames::Messages(bodies),
    }
}

/// `ended`, as the wrapper's.
pub fn ended(ended: stream::Ended) -> wrapper::Ended {
    match ended {
        stream::Ended::Exited { code } => wrapper::Ended::Exited { code },
        stream::Ended::Signalled { signal } => wrapper::Ended::Signalled { signal },
        stream::Ended::LineTooLong { stream, bound } => wrapper::Ended::LineTooLong {
            stream: stream_of(stream),
            bound,
        },
        stream::Ended::MessageTooLong { stream, bound } => wrapper::Ended::MessageTooLong {
            stream: stream_of(stream),
            bound,
        },
        stream::Ended::Failed(words) => wrapper::Ended::Failed(words),
    }
}

/// `pulled`, as the wrapper's.
pub fn pulled(pulled: stream::Pulled) -> wrapper::Pulled {
    match pulled {
        stream::Pulled::Delivered(delivery) => wrapper::Pulled::Delivered(wrapper::Delivery {
            out: frames(delivery.out),
            err: frames(delivery.err),
            ended: delivery.ended.map(ended),
        }),
        stream::Pulled::Cancelled => wrapper::Pulled::Cancelled,
    }
}
