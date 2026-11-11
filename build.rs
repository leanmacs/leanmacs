//! Builds the Lean package with Lake, compiles the C shim against the
//! matching Lean headers, and links everything into the Rust binary.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn find_tool(name: &str) -> PathBuf {
    let var = name.to_uppercase();
    if let Ok(p) = env::var(&var) {
        return p.into();
    }
    if let Ok(path) = env::var("PATH") {
        for dir in env::split_paths(&path) {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    let elan = PathBuf::from(env::var("HOME").unwrap())
        .join(".elan/bin")
        .join(name);
    if elan.is_file() {
        return elan;
    }
    panic!("could not find `{name}`; install elan or set ${var}");
}

fn run(cmd: &mut Command) -> String {
    let out = cmd
        .output()
        .unwrap_or_else(|e| panic!("failed to run {cmd:?}: {e}"));
    if !out.status.success() {
        panic!(
            "{cmd:?} failed:\n{}\n{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    String::from_utf8(out.stdout).unwrap()
}

/// The generated module initializer's symbol name varies across Lean
/// versions (it may carry a package prefix), so read it from the IR.
fn module_init_symbol(ir_c: &Path) -> String {
    let src =
        fs::read_to_string(ir_c).unwrap_or_else(|e| panic!("reading {}: {e}", ir_c.display()));
    src.lines()
        .filter_map(|l| {
            let start = l.find("initialize_")?;
            let rest = &l[start..];
            let end = rest.find('(')?;
            let sym = &rest[..end];
            (sym.ends_with("EditorHost") && l.contains("uint8_t")).then(|| sym.to_string())
        })
        .next()
        .expect("module initializer for EditorHost not found in generated C")
}

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let lean_dir = manifest.join("lean");
    for f in [
        "lakefile.toml",
        "lean-toolchain",
        "Editor.lean",
        "Editor",
        "EditorHost.lean",
    ] {
        println!("cargo:rerun-if-changed=lean/{f}");
    }
    println!("cargo:rerun-if-changed=shim/shim.c");

    let lake = find_tool("lake");
    let lean = find_tool("lean");

    // Oleans (imported at runtime by user config) + static lib (linked here).
    run(Command::new(&lake)
        .current_dir(&lean_dir)
        .args(["build", "Editor", "Editor:static"]));

    let prefix = run(Command::new(&lean)
        .current_dir(&lean_dir)
        .arg("--print-prefix"))
    .trim()
    .to_string();
    let prefix = PathBuf::from(prefix);
    let build = lean_dir.join(".lake/build");

    let init_sym = module_init_symbol(&build.join("ir/EditorHost.c"));

    cc::Build::new()
        .file("shim/shim.c")
        .include(prefix.join("include"))
        .define("EDITOR_MODULE_INIT", init_sym.as_str())
        .warnings(false)
        .compile("editor_shim");

    let lib_dir = build.join("lib");
    let static_lib = fs::read_dir(&lib_dir)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().is_some_and(|x| x == "a"))
        .expect("Lake static lib not found");

    // Keep every object in the Lean static lib and leave its symbols
    // dlsym-able: the Lean interpreter calls compiled code (and our
    // @[extern] wrappers) by looking up symbols in the running executable.
    if cfg!(target_os = "macos") {
        println!(
            "cargo:rustc-link-arg=-Wl,-force_load,{}",
            static_lib.display()
        );
        println!("cargo:rustc-link-arg=-Wl,-export_dynamic");
    } else {
        println!("cargo:rustc-link-arg=-Wl,--whole-archive");
        println!("cargo:rustc-link-arg={}", static_lib.display());
        println!("cargo:rustc-link-arg=-Wl,--no-whole-archive");
        println!("cargo:rustc-link-arg=-rdynamic");
    }

    let lean_lib = prefix.join("lib/lean");
    println!("cargo:rustc-link-search=native={}", lean_lib.display());
    println!("cargo:rustc-link-lib=dylib=leanshared");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lean_lib.display());

    println!("cargo:rustc-env=EDITOR_LEAN_SYSROOT={}", prefix.display());
    println!(
        "cargo:rustc-env=EDITOR_OLEAN_DIR={}",
        lib_dir.join("lean").display()
    );
}
