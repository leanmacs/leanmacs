//! The real [`Compile`]: the C compiler `cc` finds for the target.

use crate::ports::Compile;
use std::path::{Path, PathBuf};

/// Compiles and links a grammar's C sources as a shared library with the C
/// compiler `cc` finds for `target`, built on `host` at `opt_level`, as
/// `editor-syntax-fixture-ini`'s build script links its fixture: `cc`'s
/// compiler and flags (C11, warnings off: a grammar's generated C is
/// upstream's), then `-dynamiclib` on macOS or `-shared` elsewhere, the
/// sources, and `-o` the library. Each is taken as an argument, so a test
/// makes one outside a build script.
#[derive(Clone, Debug)]
pub struct CcCompiler {
    target: String,
    host: String,
    opt_level: String,
}

impl CcCompiler {
    /// A compiler for the target triple `target`, built on `host`, at the
    /// optimisation level `opt_level` (Cargo's `OPT_LEVEL`).
    pub fn new(target: &str, host: &str, opt_level: &str) -> Self {
        Self {
            target: target.to_owned(),
            host: host.to_owned(),
            opt_level: opt_level.to_owned(),
        }
    }

    fn link_flag(&self) -> &'static str {
        if self.target.contains("apple") {
            "-dynamiclib"
        } else {
            "-shared"
        }
    }
}

impl Compile for CcCompiler {
    fn compile(&self, sources: &[PathBuf], include: &Path, output: &Path) -> Result<(), String> {
        let compiler = cc::Build::new()
            .target(&self.target)
            .host(&self.host)
            .opt_level_str(&self.opt_level)
            .debug(false)
            .cargo_metadata(false)
            .cargo_warnings(false)
            .include(include)
            .std("c11")
            .warnings(false)
            .try_get_compiler()
            .map_err(|error| format!("no C compiler for {}: {error}", self.target))?;
        let mut command = compiler.to_command();
        command
            .arg(self.link_flag())
            .args(sources)
            .arg("-o")
            .arg(output);
        let ran = command
            .output()
            .map_err(|error| format!("running {command:?}: {error}"))?;
        if ran.status.success() {
            Ok(())
        } else {
            Err(format!(
                "{}{}",
                String::from_utf8_lossy(&ran.stderr),
                String::from_utf8_lossy(&ran.stdout)
            ))
        }
    }
}
