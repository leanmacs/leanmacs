/**
 * @file A small INI grammar: the editor's fixture of a grammar loaded from
 * a native library at run time (crates/editor-syntax-fixture-ini). It is
 * not one of the grammars compiled into the editor.
 *
 * A document is pairs and comments, then sections. A section is a name in
 * brackets on a line of its own, then its pairs and comments. A pair is a
 * key, `=` and an optional value to the end of the line. A comment starts
 * with `;` or `#` and runs to the end of the line.
 *
 * The node kinds and fields are fixed: the fixture's corpus and queries
 * name them (crates/editor-syntax-treesitter/tests/contract.rs).
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: 'ini',

  extras: (_) => [/[ \t\r]/],

  rules: {
    document: ($) => seq(repeat($._item), repeat($.section)),

    section: ($) =>
      seq('[', field('name', $.section_name), ']', repeat($._item)),

    section_name: (_) => /[^\[\]\r\n]+/,

    _item: ($) => choice($.pair, $.comment, $._newline),

    pair: ($) =>
      seq(field('key', $.key), '=', optional(field('value', $.value))),

    key: (_) => /[^\s=;#\[\]]+/,

    // Above a key, which may also start where a value may: after `=`, the
    // rest of the line is the value.
    value: (_) => token(prec(1, /[^\s;#][^\r\n]*/)),

    comment: (_) => /[;#][^\r\n]*/,

    _newline: (_) => '\n',
  },
});
