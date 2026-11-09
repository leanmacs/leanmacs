//! Prototype of the Rust <-> Lean bridge.
//!
//! Rust owns the buffer; Lean code (elaborated at runtime) edits it through
//! host primitives. Config is a list of named chunks; changing one swaps in a
//! freshly elaborated environment while Rust-side state (the buffer) lives on.
//!
//! * `cargo run`            scripted demo
//! * `cargo run -- --repl`  interactive loop (`:help` for commands)
//! * `cargo run -- --soak`  reload repeatedly and watch memory

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io::{self, BufRead, Write};
use std::time::Instant;

// ---- FFI to shim/shim.c ----

unsafe extern "C" {
    fn shim_init() -> *mut c_char;
    fn shim_session_new(sysroot: *const c_char, olean_dir: *const c_char, err: *mut *mut c_char)
    -> *mut c_void;
    fn shim_session_free(s: *mut c_void);
    fn shim_session_eval(s: *mut c_void, src: *const c_char, out: *mut *mut c_char) -> c_int;
    fn shim_session_run(s: *mut c_void, name: *const c_char, out: *mut *mut c_char) -> c_int;
    fn shim_session_set_chunk(
        s: *mut c_void,
        name: *const c_char,
        src: *const c_char,
        out: *mut *mut c_char,
    ) -> c_int;
    fn shim_session_remove_chunk(s: *mut c_void, name: *const c_char, out: *mut *mut c_char)
    -> c_int;
    fn shim_free(p: *mut c_char);
}

/// Takes ownership of a malloc'd C string from the shim.
fn take_string(p: *mut c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { shim_free(p) };
    s
}

// ---- Host state + primitives called from Lean ----

thread_local! {
    static BUFFER: RefCell<String> = const { RefCell::new(String::new()) };
    /// Keeps the bytes handed to Lean alive for the duration of the call.
    static SNAPSHOT: RefCell<String> = const { RefCell::new(String::new()) };
}

unsafe fn str_from_raw<'a>(ptr: *const c_char, len: usize) -> &'a str {
    // Lean strings are always valid UTF-8.
    unsafe { std::str::from_utf8_unchecked(std::slice::from_raw_parts(ptr.cast(), len)) }
}

#[unsafe(no_mangle)]
extern "C" fn rust_host_insert(ptr: *const c_char, len: usize) {
    let s = unsafe { str_from_raw(ptr, len) };
    BUFFER.with(|b| b.borrow_mut().push_str(s));
}

#[unsafe(no_mangle)]
extern "C" fn rust_host_buffer_text(ptr: *mut *const c_char, len: *mut usize) {
    SNAPSHOT.with(|snap| {
        let mut snap = snap.borrow_mut();
        *snap = BUFFER.with(|b| b.borrow().clone());
        unsafe {
            *ptr = snap.as_ptr().cast();
            *len = snap.len();
        }
    });
}

#[unsafe(no_mangle)]
extern "C" fn rust_host_message(ptr: *const c_char, len: usize) {
    println!("  [echo] {}", unsafe { str_from_raw(ptr, len) });
}

// ---- Safe wrapper ----

type Outcome = (bool, String);

struct Session(*mut c_void);

fn cstr(s: &str) -> CString {
    CString::new(s).expect("interior NUL")
}

impl Session {
    fn new() -> Result<Self, String> {
        let err = unsafe { shim_init() };
        if !err.is_null() {
            return Err(take_string(err));
        }
        let sysroot = cstr(env!("EDITOR_LEAN_SYSROOT"));
        let oleans = cstr(env!("EDITOR_OLEAN_DIR"));
        let mut err = std::ptr::null_mut();
        let s = unsafe { shim_session_new(sysroot.as_ptr(), oleans.as_ptr(), &mut err) };
        if s.is_null() { Err(take_string(err)) } else { Ok(Session(s)) }
    }

    fn call(f: impl FnOnce(*mut *mut c_char) -> c_int) -> Outcome {
        let mut out = std::ptr::null_mut();
        let ok = f(&mut out);
        (ok != 0, take_string(out))
    }

    /// Scratch commands on top of the current state (lost on next reload).
    fn eval(&self, src: &str) -> Outcome {
        let src = cstr(src);
        Self::call(|out| unsafe { shim_session_eval(self.0, src.as_ptr(), out) })
    }

    /// Run a declaration of type `EditorM Unit`.
    fn run(&self, name: &str) -> Outcome {
        let name = cstr(name);
        Self::call(|out| unsafe { shim_session_run(self.0, name.as_ptr(), out) })
    }

    /// Add or replace a config chunk. Atomic: on failure nothing changes.
    fn set_chunk(&self, name: &str, src: &str) -> Outcome {
        let (name, src) = (cstr(name), cstr(src));
        Self::call(|out| unsafe { shim_session_set_chunk(self.0, name.as_ptr(), src.as_ptr(), out) })
    }

    fn remove_chunk(&self, name: &str) -> Outcome {
        let name = cstr(name);
        Self::call(|out| unsafe { shim_session_remove_chunk(self.0, name.as_ptr(), out) })
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        unsafe { shim_session_free(self.0) };
    }
}

// ---- Driver ----

fn report(label: &str, start: Instant, (ok, out): Outcome) {
    let ms = start.elapsed().as_secs_f64() * 1000.0;
    println!("{label}: {} ({ms:.1} ms)", if ok { "ok" } else { "FAILED" });
    for line in out.lines() {
        println!("  | {line}");
    }
}

fn show_buffer() {
    BUFFER.with(|b| println!("buffer = {:?}\n", b.borrow()));
}

enum Step {
    Chunk(&'static str, &'static str),
    Remove(&'static str),
    Eval(&'static str),
    Run(&'static str),
    Note(&'static str),
}

const DEMO: &[Step] = &[
    Step::Note("Two config chunks: `util` defines helpers, `cmds` uses them."),
    Step::Chunk("util", "def greeting : String := \"hello\"\ndef line (s : String) : EditorM Unit := insertText (s ++ \"\\n\")"),
    Step::Chunk("cmds", "def greet : EditorM Unit := line s!\"{greeting}, world\""),
    Step::Run("greet"),
    Step::Note("Redefine `greet` by replacing its chunk: only `cmds` is re-elaborated."),
    Step::Chunk("cmds", "def greet : EditorM Unit := line s!\"{greeting.toUpper}!!\""),
    Step::Run("greet"),
    Step::Note("Change `util`: `cmds` depends on it, so both are re-elaborated."),
    Step::Chunk("util", "def greeting : String := \"bonjour\"\ndef line (s : String) : EditorM Unit := insertText (\"> \" ++ s ++ \"\\n\")"),
    Step::Run("greet"),
    Step::Note("Break `util` (drop `line`): `cmds` no longer elaborates, so the reload is rejected."),
    Step::Chunk("util", "def greeting : String := \"hola\""),
    Step::Run("greet"),
    Step::Note("Proofs in config are checked against the current definitions (`greeting` is \"bonjour\")."),
    Step::Chunk("facts", "theorem greeting_short : greeting.length < 5 := by decide"),
    Step::Chunk("facts", "theorem greeting_short : greeting.length < 10 := by decide"),
    Step::Note("Scratch evals live on top of the config, until the next reload."),
    Step::Eval("def scratch : EditorM Unit := line \"from scratch\""),
    Step::Run("scratch"),
    Step::Remove("facts"),
    Step::Run("scratch"),
];

fn demo(session: &Session) {
    for step in DEMO {
        let start = Instant::now();
        match step {
            Step::Note(n) => {
                println!("## {n}\n");
                continue;
            }
            Step::Chunk(name, src) => {
                println!("> chunk {name}:");
                for l in src.lines() {
                    println!("    {l}");
                }
                report("set-chunk", start, session.set_chunk(name, src));
            }
            Step::Remove(name) => {
                println!("> remove chunk {name}");
                report("remove-chunk", start, session.remove_chunk(name));
            }
            Step::Eval(src) => {
                println!("> eval {src}");
                report("eval", start, session.eval(src));
            }
            Step::Run(name) => {
                println!("> run {name}");
                report("run", start, session.run(name));
                show_buffer();
                continue;
            }
        }
        println!();
    }
}

/// Reload a chunk many times and report resident memory, to check that
/// swapped-out environments are actually freed.
fn soak(session: &Session) {
    let rss_mb = || -> f64 {
        let pid = std::process::id().to_string();
        let out = std::process::Command::new("ps").args(["-o", "rss=", "-p", &pid]).output();
        out.ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|s| s.trim().parse::<f64>().ok())
            .map_or(f64::NAN, |kb| kb / 1024.0)
    };
    // A chunk with a bit of weight: 50 definitions and a proof.
    let mut src = String::new();
    for i in 0..50 {
        src += &format!("def f{i} (n : Nat) : Nat := n * {i} + {i}\n");
    }
    src += "theorem f1_spec (n : Nat) : f1 n = n + 1 := by simp [f1]\n";
    println!("rss at start: {:.1} MB", rss_mb());
    let start = Instant::now();
    for round in 1..=500 {
        let (ok, out) = session.set_chunk("soak", &format!("{src}def round : Nat := {round}\n"));
        assert!(ok, "reload failed: {out}");
        if round % 100 == 0 {
            let avg = start.elapsed().as_secs_f64() * 1000.0 / round as f64;
            println!("after {round:>3} reloads: rss {:.1} MB, avg {avg:.2} ms/reload", rss_mb());
        }
    }
}

const HELP: &str = "\
Lean commands are buffered until a line containing only `;;`, then elaborated
as scratch (discarded on the next reload).

  :load NAME FILE   add/replace config chunk NAME from FILE
  :reload           re-read every loaded file, re-elaborating changed chunks
  :rm NAME          remove a chunk
  :run NAME         run an `EditorM Unit` command
  :buf              show the buffer
  :q                quit";

fn repl(session: &Session) {
    println!("{HELP}\n");
    // chunk name -> (file, last source that elaborated successfully)
    let mut files: BTreeMap<String, (String, String)> = BTreeMap::new();
    let load = |file: &str| -> Result<String, String> {
        std::fs::read_to_string(file).map_err(|e| format!("{file}: {e}"))
    };
    let stdin = io::stdin();
    let mut pending = String::new();
    loop {
        print!("{}", if pending.is_empty() { "lean> " } else { "....> " });
        io::stdout().flush().unwrap();
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).unwrap() == 0 {
            break;
        }
        let trimmed = line.trim();
        if pending.is_empty() && trimmed.starts_with(':') {
            let mut words = trimmed.split_whitespace();
            let cmd = words.next().unwrap();
            let args: Vec<&str> = words.collect();
            let start = Instant::now();
            match (cmd, args.as_slice()) {
                (":load", [name, file]) => match load(file) {
                    Ok(src) => {
                        let res = session.set_chunk(name, &src);
                        if res.0 {
                            files.insert(name.to_string(), (file.to_string(), src));
                        }
                        report("load", start, res);
                    }
                    Err(e) => println!("{e}"),
                },
                (":reload", []) => {
                    // Reloading in order means the first changed chunk
                    // re-elaborates everything after it once; later changed
                    // chunks then re-elaborate a shorter suffix again. Fine
                    // for a prototype.
                    let mut any = false;
                    for (name, (file, last)) in files.iter_mut() {
                        match load(file) {
                            Ok(src) if src != *last => {
                                any = true;
                                let res = session.set_chunk(name, &src);
                                if res.0 {
                                    *last = src;
                                }
                                report(&format!("reload {name}"), start, res);
                            }
                            Ok(_) => {}
                            Err(e) => println!("{e}"),
                        }
                    }
                    if !any {
                        println!("nothing changed");
                    }
                }
                (":rm", [name]) => {
                    let res = session.remove_chunk(name);
                    if res.0 {
                        files.remove(*name);
                    }
                    report("rm", start, res);
                }
                (":run", [name]) => {
                    report("run", start, session.run(name));
                    show_buffer();
                }
                (":buf", []) => show_buffer(),
                (":help", []) => println!("{HELP}"),
                (":q", []) => break,
                _ => println!("unknown command; :help for help"),
            }
            continue;
        }
        if trimmed == ";;" {
            let start = Instant::now();
            report("eval", start, session.eval(&pending));
            pending.clear();
        } else if !(pending.is_empty() && trimmed.is_empty()) {
            pending.push_str(&line);
        }
    }
}

fn main() {
    let start = Instant::now();
    let session = match Session::new() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("failed to start Lean: {e}");
            std::process::exit(1);
        }
    };
    println!(
        "Lean runtime + `import Editor` ready in {:.1} ms\n",
        start.elapsed().as_secs_f64() * 1000.0
    );
    let arg = std::env::args().nth(1);
    match arg.as_deref() {
        Some("--repl") => repl(&session),
        Some("--soak") => soak(&session),
        _ => demo(&session),
    }
}
