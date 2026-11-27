//! Prints the report of the package's grammar build on standard output, one
//! line a grammar, `built<TAB><name><TAB><library>` or
//! `failed<TAB><name><TAB><reason>`, and each failed compile's output on
//! standard error. The set's build runs it with Cargo (the package's
//! `editorGrammarSources` input file; `editorGrammars` in
//! `lean/lakefile.lean`) and stages each library it names.

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
