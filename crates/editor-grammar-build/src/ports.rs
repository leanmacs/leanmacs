//! The ports the core reaches the outside world through, each in the
//! core's own terms: where a Cargo package's source is ([`Locate`]),
//! whether a file of a grammar's source is there ([`SourceTree`]), and
//! compiling sources into a shared library ([`Compile`]). The real adapters
//! are [`crate::CargoMetadata`], [`crate::RealTree`] and
//! [`crate::CcCompiler`]; the core's tests run on hand-written fakes.

use std::path::{Path, PathBuf};

/// Where a Cargo package that the calling crate depends on keeps its
/// source.
pub trait Locate {
    /// The directory of the package named `package`, the one holding its
    /// `Cargo.toml`; or why it cannot be found, as a sentence naming it.
    fn locate(&self, package: &str) -> Result<PathBuf, String>;
}

/// Whether a file of a grammar's source is there.
pub trait SourceTree {
    /// Whether `path` names a file.
    fn has_file(&self, path: &Path) -> bool;
}

/// Compiles C sources into a shared library.
pub trait Compile {
    /// Compiles and links `sources`, their headers found under `include`,
    /// as the shared library `output`; or the compiler's output when it
    /// fails.
    fn compile(&self, sources: &[PathBuf], include: &Path, output: &Path) -> Result<(), String>;
}
