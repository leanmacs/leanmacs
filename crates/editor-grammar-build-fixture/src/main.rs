//! Prints the report of the fixture's grammar build on standard output, and
//! the failed compile's output on standard error, as a package's
//! grammar-source crate's binary does, for the set's build to read
//! (`editor-grammar-build`'s crate docs).

fn main() {
    print!(
        "{}",
        include_str!(concat!(env!("OUT_DIR"), "/grammars.report"))
    );
    eprint!(
        "{}",
        include_str!(concat!(env!("OUT_DIR"), "/grammars.stderr"))
    );
}
