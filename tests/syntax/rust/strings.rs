fn main() {
    let greeting = "héllo, \"wörld\"\n\t\u{1F600}";
    let raw = r#"a "raw" string"#;
    let bytes = b"bytes\x00";
    /* a block comment
       over two lines */
    println!("{greeting} {raw} {:?} {}", bytes, 'c');
    assert_eq!(vec![1, 2, 3].len(), 3, "three");
}
