//! The real [`SourceTree`]: the disk.

use crate::ports::SourceTree;
use std::path::Path;

/// Asks the disk whether a file is there.
#[derive(Clone, Copy, Debug, Default)]
pub struct RealTree;

impl SourceTree for RealTree {
    fn has_file(&self, path: &Path) -> bool {
        #[expect(
            clippy::disallowed_methods,
            reason = "the real source tree asks the disk whether a grammar's source file is there"
        )]
        let file = path.is_file();
        file
    }
}
