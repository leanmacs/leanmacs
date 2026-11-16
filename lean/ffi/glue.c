// Glue between Lean's `@[extern]` calling convention and the Rust library's
// plain C ABI (`crates/editor-ffi`).
//
// Building and taking apart Lean objects is done with `lean.h`, most of which
// is `static inline`, so it has to be done in C. A wrapper here calls one Rust
// function and builds the Lean value for its result. Calls go one way: the
// wrappers never call Lean code. The entry point at the bottom of the file
// starts Lean, once, by calling the `main` Lean generates.
//
// This file stays C, and it installs no terminate or signal handler. A C++
// exception from Lean's interpreter is not caught anywhere: it ends the
// process, on purpose (`Editor/Ffi.lean`, "An exception from the interpreter
// ends the process"). `mise run ffi-overflow` shows it, on demand; it is not
// part of the gate.
//
// The conventions the wrappers follow are in the module docs of
// `Editor/Ffi.lean`. `FfiTest.lean` pins what this file does, as Lean sees
// it.

// For `pthread_getattr_np` on Linux, which glibc declares only when this is
// defined before the first include. It changes nothing on macOS.
#define _GNU_SOURCE

#include <lean/lean.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The Rust library.
bool editor_ffi_is_main_thread(void);
bool editor_ffi_main_thread_probe(void);
void editor_ffi_main_thread_open(void);
_Noreturn void editor_ffi_main_thread_serve(void);

// `Editor.Ffi.isMainThread : IO Bool`
lean_obj_res editor_glue_is_main_thread(void) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_is_main_thread()));
}

// `Editor.Ffi.mainThreadProbe : IO Bool`
lean_obj_res editor_glue_main_thread_probe(void) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_main_thread_probe()));
}

// ---- Handles ----
//
// A Rust object crosses to Lean as an external object: a Lean object that
// carries the Rust pointer and belongs to a class whose finaliser Lean runs
// when the last reference is dropped. The finaliser is the only caller of the
// Rust `free` function. There is one class per Rust type, registered on first
// use.

// The Rust library's counter.
typedef struct editor_ffi_counter editor_ffi_counter;
editor_ffi_counter *editor_ffi_counter_new(uint64_t start);
uint64_t editor_ffi_counter_increment(const editor_ffi_counter *counter);
void editor_ffi_counter_free(editor_ffi_counter *counter);
uint64_t editor_ffi_counter_live(void);

static lean_external_class *counter_class;
static pthread_once_t counter_class_once = PTHREAD_ONCE_INIT;

// Runs when Lean drops the last reference to a counter, on whichever thread
// dropped it.
static void counter_finalize(void *counter) {
  editor_ffi_counter_free(counter);
}

// A counter holds no Lean objects, so there is nothing to visit.
static void counter_foreach(void *counter, b_lean_obj_arg visitor) {
  (void)counter;
  (void)visitor;
}

static void counter_class_register(void) {
  counter_class =
      lean_register_external_class(counter_finalize, counter_foreach);
}

// `Editor.Ffi.Counter.new : UInt64 → IO Counter`
lean_obj_res editor_glue_counter_new(uint64_t start) {
  pthread_once(&counter_class_once, counter_class_register);
  return lean_io_result_mk_ok(
      lean_alloc_external(counter_class, editor_ffi_counter_new(start)));
}

// `Editor.Ffi.Counter.increment : @& Counter → IO UInt64`
lean_obj_res editor_glue_counter_increment(b_lean_obj_arg counter) {
  return lean_io_result_mk_ok(lean_box_uint64(
      editor_ffi_counter_increment(lean_get_external_data(counter))));
}

// `Editor.Ffi.Counter.live : IO UInt64`
lean_obj_res editor_glue_counter_live(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_counter_live()));
}

// ---- Plain data ----
//
// A string goes to Rust as a pointer and a byte length, borrowed for the
// call. A structure comes back as one C record filled through an out-pointer
// in a single call, and the Lean structure is built from it here. Text in a
// record is a buffer the library owns: it is copied into a Lean string and
// handed straight back with `editor_ffi_text_free`.
//
// A Lean structure built here declares its object fields first and `UInt64`
// fields after them and nothing else, so the order of its declaration is its
// layout: object field `i` is `lean_ctor_set(o, i, …)`, and `UInt64` field
// `j` is at byte `objects * sizeof(void *) + 8 * j`.

// The byte offset of the `index`th `UInt64` field of a constructor with
// `objects` object fields.
static unsigned uint64_field(unsigned objects, unsigned index) {
  return objects * sizeof(void *) + index * sizeof(uint64_t);
}

// The bytes of a Lean string, without the terminating NUL `lean.h` counts.
static const uint8_t *string_bytes(b_lean_obj_arg string) {
  return (const uint8_t *)lean_string_cstr(string);
}
static size_t string_len(b_lean_obj_arg string) {
  return lean_string_size(string) - 1;
}

// `some value`, for an `Option` built here; `none` is `lean_box(0)`.
static lean_object *option_some(lean_object *value) {
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, value);
  return some;
}

void editor_ffi_text_free(uint8_t *text, size_t len);

// The library's `ByteRange`.
typedef struct {
  uint64_t start;
  uint64_t end;
} editor_ffi_byte_range;
bool editor_ffi_text_find(const uint8_t *haystack, size_t haystack_len,
                          const uint8_t *needle, size_t needle_len,
                          bool has_start, size_t start,
                          editor_ffi_byte_range *out);

// `Editor.Ffi.findRaw : @& String → @& String → Bool → USize → Option
// ByteRange`. Pure, so the result is the value itself, not an `IO` result.
lean_obj_res editor_glue_text_find(b_lean_obj_arg haystack,
                                   b_lean_obj_arg needle, uint8_t has_start,
                                   size_t start) {
  editor_ffi_byte_range found;
  if (!editor_ffi_text_find(string_bytes(haystack), string_len(haystack),
                            string_bytes(needle), string_len(needle), has_start,
                            start, &found)) {
    return lean_box(0); // `none`
  }
  // `ByteRange`: no object fields, then `start` and `stop`.
  lean_object *range = lean_alloc_ctor(0, 0, 2 * sizeof(uint64_t));
  lean_ctor_set_uint64(range, uint64_field(0, 0), found.start);
  lean_ctor_set_uint64(range, uint64_field(0, 1), found.end);
  return option_some(range);
}

// ---- The document ----
//
// A second handle, whose functions take a string and hand one back. It is
// the text the editor's text port is bound to (`Editor/Text/Real.lean`).

// The Rust library's document.
typedef struct editor_ffi_document editor_ffi_document;
// The library's `RawText`.
typedef struct {
  uint8_t *text;
  size_t text_len;
} editor_ffi_raw_text;
editor_ffi_document *editor_ffi_document_new(const uint8_t *text, size_t len);
bool editor_ffi_document_replace(const editor_ffi_document *document,
                                 size_t start, size_t end, const uint8_t *text,
                                 size_t len);
void editor_ffi_document_read(const editor_ffi_document *document,
                              editor_ffi_raw_text *out);
void editor_ffi_document_free(editor_ffi_document *document);
uint64_t editor_ffi_document_live(void);

static lean_external_class *document_class;
static pthread_once_t document_class_once = PTHREAD_ONCE_INIT;

// Runs when Lean drops the last reference to a document, on whichever thread
// dropped it. The only caller of the library's `free`.
static void document_finalize(void *document) {
  editor_ffi_document_free(document);
}

// A document holds no Lean objects, so there is nothing to visit.
static void document_foreach(void *document, b_lean_obj_arg visitor) {
  (void)document;
  (void)visitor;
}

static void document_class_register(void) {
  document_class =
      lean_register_external_class(document_finalize, document_foreach);
}

// `Editor.Ffi.Document.new : @& String → IO Document`
lean_obj_res editor_glue_document_new(b_lean_obj_arg text) {
  pthread_once(&document_class_once, document_class_register);
  return lean_io_result_mk_ok(lean_alloc_external(
      document_class,
      editor_ffi_document_new(string_bytes(text), string_len(text))));
}

// `Editor.Ffi.Document.replace : @& Document → USize → USize → @& String →
// IO Bool`
lean_obj_res editor_glue_document_replace(b_lean_obj_arg document, size_t start,
                                          size_t stop, b_lean_obj_arg text) {
  return lean_io_result_mk_ok(lean_box(
      editor_ffi_document_replace(lean_get_external_data(document), start, stop,
                                  string_bytes(text), string_len(text))));
}

// `Editor.Ffi.Document.read : @& Document → IO String`
lean_obj_res editor_glue_document_read(b_lean_obj_arg document) {
  editor_ffi_raw_text raw;
  editor_ffi_document_read(lean_get_external_data(document), &raw);
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  return lean_io_result_mk_ok(text);
}

// `Editor.Ffi.Document.live : IO UInt64`
lean_obj_res editor_glue_document_live(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_document_live()));
}

// ---- A document's transactions and its edit log ----
//
// The example of lists crossing. A list is words: a buffer of 64-bit numbers,
// eight bytes each, least significant first. Lean writes and reads the words
// (`Editor/Ffi.lean`) and Rust reads and writes them (`words.rs` in
// `editor-ffi`); the glue knows only that they are bytes. A `ByteArray` goes
// to Rust as a pointer and a length, borrowed for the call, and a buffer of
// words the library owns is copied into a `ByteArray` and handed straight
// back with `editor_ffi_text_free`, as text is.

// The bytes of a Lean `ByteArray`, and how many there are.
static const uint8_t *byte_array_bytes(b_lean_obj_arg bytes) {
  return lean_sarray_cptr(bytes);
}
static size_t byte_array_len(b_lean_obj_arg bytes) {
  return lean_sarray_size(bytes);
}

// A new `ByteArray` holding a copy of the `len` bytes at `bytes`.
static lean_object *byte_array_copy(const uint8_t *bytes, size_t len) {
  lean_object *array = lean_alloc_sarray(1, len, len);
  if (len != 0) {
    memcpy(lean_sarray_cptr(array), bytes, len);
  }
  return array;
}

// The library's `RawApplied`.
typedef struct {
  uint64_t status;
  uint64_t revision;
} editor_ffi_raw_applied;
// The library's `RawWords`.
typedef struct {
  uint64_t status;
  uint8_t *words;
  size_t len;
} editor_ffi_raw_words;
void editor_ffi_document_apply(const editor_ffi_document *document,
                               const uint8_t *words, size_t words_len,
                               const uint8_t *inserted, size_t inserted_len,
                               uint64_t origin, editor_ffi_raw_applied *out);
void editor_ffi_document_changes_since(const editor_ffi_document *document,
                                       uint64_t revision,
                                       editor_ffi_raw_words *out);
bool editor_ffi_document_trace(const editor_ffi_document *document,
                               size_t start, size_t end,
                               editor_ffi_raw_words *out);
bool editor_ffi_document_forget(const editor_ffi_document *document,
                                uint64_t revision);

// `Editor.Ffi.Document.applyRaw : @& Document → @& ByteArray → @& String →
// UInt64 → IO RawApplied`
lean_obj_res editor_glue_document_apply(b_lean_obj_arg document,
                                        b_lean_obj_arg words,
                                        b_lean_obj_arg inserted,
                                        uint64_t origin) {
  editor_ffi_raw_applied raw;
  editor_ffi_document_apply(lean_get_external_data(document),
                            byte_array_bytes(words), byte_array_len(words),
                            string_bytes(inserted), string_len(inserted),
                            origin, &raw);
  // `RawApplied`: no object fields, then `status` and `revision`.
  lean_object *applied = lean_alloc_ctor(0, 0, 2 * sizeof(uint64_t));
  lean_ctor_set_uint64(applied, uint64_field(0, 0), raw.status);
  lean_ctor_set_uint64(applied, uint64_field(0, 1), raw.revision);
  return lean_io_result_mk_ok(applied);
}

// `Editor.Ffi.Document.changesSinceRaw : @& Document → UInt64 → IO RawWords`
lean_obj_res editor_glue_document_changes_since(b_lean_obj_arg document,
                                                uint64_t revision) {
  editor_ffi_raw_words raw;
  editor_ffi_document_changes_since(lean_get_external_data(document), revision,
                                    &raw);
  // `RawWords`: the object field `words`, then `status`.
  lean_object *words = lean_alloc_ctor(0, 1, sizeof(uint64_t));
  lean_ctor_set(words, 0, byte_array_copy(raw.words, raw.len));
  lean_ctor_set_uint64(words, uint64_field(1, 0), raw.status);
  editor_ffi_text_free(raw.words, raw.len);
  return lean_io_result_mk_ok(words);
}

// `Editor.Ffi.Document.traceRaw : @& Document → USize → USize → IO (Option
// ByteArray)`
lean_obj_res editor_glue_document_trace(b_lean_obj_arg document, size_t start,
                                        size_t stop) {
  editor_ffi_raw_words raw;
  if (!editor_ffi_document_trace(lean_get_external_data(document), start, stop,
                                 &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  lean_object *words = byte_array_copy(raw.words, raw.len);
  editor_ffi_text_free(raw.words, raw.len);
  return lean_io_result_mk_ok(option_some(words));
}

// `Editor.Ffi.Document.forget : @& Document → UInt64 → IO Bool`
lean_obj_res editor_glue_document_forget(b_lean_obj_arg document,
                                         uint64_t revision) {
  return lean_io_result_mk_ok(lean_box(
      editor_ffi_document_forget(lean_get_external_data(document), revision)));
}

// ---- The snapshot ----
//
// A third handle: a text as it was at one moment. It is made by a call on a
// document, not by a `new` function, and it outlives the document; the file
// service hands one over too, as the text of a file it loaded (below). Its
// functions hand back a record of numbers and take the tag of Lean's
// `Editor.Ffi.ColumnUnit`, which the library checks. A motion is a tag too,
// with two numbers, and one row or a range of the text comes back as an
// option of a string.

// The Rust library's snapshot.
typedef struct editor_ffi_snapshot editor_ffi_snapshot;
// The library's `RawSnapshotInfo`.
typedef struct {
  uint64_t revision;
  uint64_t byte_len;
  uint64_t row_count;
} editor_ffi_raw_snapshot_info;
// The library's `RawPoint`.
typedef struct {
  uint64_t row;
  uint64_t column;
} editor_ffi_raw_point;
editor_ffi_snapshot *
editor_ffi_document_snapshot(const editor_ffi_document *document);
editor_ffi_document *
editor_ffi_document_from_snapshot(const editor_ffi_snapshot *snapshot);
void editor_ffi_snapshot_info(const editor_ffi_snapshot *snapshot,
                              editor_ffi_raw_snapshot_info *out);
void editor_ffi_snapshot_read(const editor_ffi_snapshot *snapshot,
                              editor_ffi_raw_text *out);
bool editor_ffi_snapshot_point_of(const editor_ffi_snapshot *snapshot,
                                  uint8_t unit, size_t offset,
                                  editor_ffi_raw_point *out);
bool editor_ffi_snapshot_offset_of(const editor_ffi_snapshot *snapshot,
                                   uint8_t unit, uint64_t row, uint64_t column,
                                   uint64_t *out);
bool editor_ffi_snapshot_motion(const editor_ffi_snapshot *snapshot,
                                uint8_t motion, uint64_t count, uint64_t column,
                                size_t offset, uint64_t *out);
bool editor_ffi_snapshot_row(const editor_ffi_snapshot *snapshot, uint64_t row,
                             editor_ffi_raw_text *out);
bool editor_ffi_snapshot_slice(const editor_ffi_snapshot *snapshot,
                               size_t start, size_t end,
                               editor_ffi_raw_text *out);
void editor_ffi_snapshot_free(editor_ffi_snapshot *snapshot);
uint64_t editor_ffi_snapshot_live(void);

static lean_external_class *snapshot_class;
static pthread_once_t snapshot_class_once = PTHREAD_ONCE_INIT;

// Runs when Lean drops the last reference to a snapshot, on whichever thread
// dropped it. The only caller of the library's `free`.
static void snapshot_finalize(void *snapshot) {
  editor_ffi_snapshot_free(snapshot);
}

// A snapshot holds no Lean objects, so there is nothing to visit.
static void snapshot_foreach(void *snapshot, b_lean_obj_arg visitor) {
  (void)snapshot;
  (void)visitor;
}

static void snapshot_class_register(void) {
  snapshot_class =
      lean_register_external_class(snapshot_finalize, snapshot_foreach);
}

// `Editor.Ffi.Document.snapshot : @& Document → IO Snapshot`
lean_obj_res editor_glue_document_snapshot(b_lean_obj_arg document) {
  pthread_once(&snapshot_class_once, snapshot_class_register);
  return lean_io_result_mk_ok(lean_alloc_external(
      snapshot_class,
      editor_ffi_document_snapshot(lean_get_external_data(document))));
}

// `Editor.Ffi.Document.ofSnapshot : @& Snapshot → IO Document`. The second
// way a document is made: from a snapshot, which is only read.
lean_obj_res editor_glue_document_from_snapshot(b_lean_obj_arg snapshot) {
  pthread_once(&document_class_once, document_class_register);
  return lean_io_result_mk_ok(lean_alloc_external(
      document_class,
      editor_ffi_document_from_snapshot(lean_get_external_data(snapshot))));
}

// `Editor.Ffi.Snapshot.info : @& Snapshot → IO SnapshotInfo`
lean_obj_res editor_glue_snapshot_info(b_lean_obj_arg snapshot) {
  editor_ffi_raw_snapshot_info raw;
  editor_ffi_snapshot_info(lean_get_external_data(snapshot), &raw);
  // `SnapshotInfo`: no object fields, then `revision`, `byteLength` and
  // `rowCount`.
  lean_object *info = lean_alloc_ctor(0, 0, 3 * sizeof(uint64_t));
  lean_ctor_set_uint64(info, uint64_field(0, 0), raw.revision);
  lean_ctor_set_uint64(info, uint64_field(0, 1), raw.byte_len);
  lean_ctor_set_uint64(info, uint64_field(0, 2), raw.row_count);
  return lean_io_result_mk_ok(info);
}

// `Editor.Ffi.Snapshot.read : @& Snapshot → IO String`
lean_obj_res editor_glue_snapshot_read(b_lean_obj_arg snapshot) {
  editor_ffi_raw_text raw;
  editor_ffi_snapshot_read(lean_get_external_data(snapshot), &raw);
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  return lean_io_result_mk_ok(text);
}

// `Editor.Ffi.Snapshot.pointOf : @& Snapshot → ColumnUnit → USize → IO
// (Option Point)`
lean_obj_res editor_glue_snapshot_point_of(b_lean_obj_arg snapshot,
                                           uint8_t unit, size_t offset) {
  editor_ffi_raw_point raw;
  if (!editor_ffi_snapshot_point_of(lean_get_external_data(snapshot), unit,
                                    offset, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  // `Point`: no object fields, then `row` and `column`.
  lean_object *point = lean_alloc_ctor(0, 0, 2 * sizeof(uint64_t));
  lean_ctor_set_uint64(point, uint64_field(0, 0), raw.row);
  lean_ctor_set_uint64(point, uint64_field(0, 1), raw.column);
  return lean_io_result_mk_ok(option_some(point));
}

// `Editor.Ffi.Snapshot.offsetOf : @& Snapshot → ColumnUnit → UInt64 → UInt64
// → IO (Option UInt64)`
lean_obj_res editor_glue_snapshot_offset_of(b_lean_obj_arg snapshot,
                                            uint8_t unit, uint64_t row,
                                            uint64_t column) {
  uint64_t offset;
  if (!editor_ffi_snapshot_offset_of(lean_get_external_data(snapshot), unit,
                                     row, column, &offset)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(option_some(lean_box_uint64(offset)));
}

// `Editor.Ffi.Snapshot.motionRaw : @& Snapshot → UInt8 → UInt64 → UInt64 →
// USize → IO (Option UInt64)`. The tag is one Lean's `Motion.encode` wrote,
// and the library checks it.
lean_obj_res editor_glue_snapshot_motion(b_lean_obj_arg snapshot,
                                         uint8_t motion, uint64_t count,
                                         uint64_t column, size_t offset) {
  uint64_t answer;
  if (!editor_ffi_snapshot_motion(lean_get_external_data(snapshot), motion,
                                  count, column, offset, &answer)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(option_some(lean_box_uint64(answer)));
}

// The `some` of a text the library lent in `raw`, copied, with the buffer
// handed back.
static lean_object *some_text(editor_ffi_raw_text raw) {
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  return option_some(text);
}

// `Editor.Ffi.Snapshot.row : @& Snapshot → UInt64 → IO (Option String)`
lean_obj_res editor_glue_snapshot_row(b_lean_obj_arg snapshot, uint64_t row) {
  editor_ffi_raw_text raw;
  if (!editor_ffi_snapshot_row(lean_get_external_data(snapshot), row, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(some_text(raw));
}

// `Editor.Ffi.Snapshot.slice : @& Snapshot → USize → USize → IO (Option
// String)`
lean_obj_res editor_glue_snapshot_slice(b_lean_obj_arg snapshot, size_t start,
                                        size_t stop) {
  editor_ffi_raw_text raw;
  if (!editor_ffi_snapshot_slice(lean_get_external_data(snapshot), start, stop,
                                 &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(some_text(raw));
}

// `Editor.Ffi.Snapshot.live : IO UInt64`
lean_obj_res editor_glue_snapshot_live(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_snapshot_live()));
}

// ---- A document's markers, and what a selection covers ----
//
// Words in both directions for one value: a marker goes to the library as
// words and comes back as words, and a selection goes in as words and what it
// covers comes back as words. As with a transaction, the glue knows only that
// they are bytes.

// The library's `RawMarked`.
typedef struct {
  uint64_t status;
  uint64_t id;
} editor_ffi_raw_marked;
void editor_ffi_document_mark(const editor_ffi_document *document,
                              const uint8_t *words, size_t len,
                              editor_ffi_raw_marked *out);
void editor_ffi_document_marker(const editor_ffi_document *document,
                                uint64_t id, editor_ffi_raw_words *out);
uint64_t editor_ffi_document_place(const editor_ffi_document *document,
                                   uint64_t id, const uint8_t *words,
                                   size_t len);
bool editor_ffi_document_unmark(const editor_ffi_document *document,
                                uint64_t id);
void editor_ffi_snapshot_extents(const editor_ffi_snapshot *snapshot,
                                 const uint8_t *words, size_t len,
                                 editor_ffi_raw_words *out);

// Lean's `RawWords` for a record the library filled: a copy of its words and
// its status. The library's buffer is handed back.
static lean_object *raw_words_take(editor_ffi_raw_words raw) {
  // `RawWords`: the object field `words`, then `status`.
  lean_object *words = lean_alloc_ctor(0, 1, sizeof(uint64_t));
  lean_ctor_set(words, 0, byte_array_copy(raw.words, raw.len));
  lean_ctor_set_uint64(words, uint64_field(1, 0), raw.status);
  editor_ffi_text_free(raw.words, raw.len);
  return words;
}

// `Editor.Ffi.Document.markRaw : @& Document → @& ByteArray → IO RawMarked`
lean_obj_res editor_glue_document_mark(b_lean_obj_arg document,
                                       b_lean_obj_arg words) {
  editor_ffi_raw_marked raw;
  editor_ffi_document_mark(lean_get_external_data(document),
                           byte_array_bytes(words), byte_array_len(words),
                           &raw);
  // `RawMarked`: no object fields, then `status` and `id`.
  lean_object *marked = lean_alloc_ctor(0, 0, 2 * sizeof(uint64_t));
  lean_ctor_set_uint64(marked, uint64_field(0, 0), raw.status);
  lean_ctor_set_uint64(marked, uint64_field(0, 1), raw.id);
  return lean_io_result_mk_ok(marked);
}

// `Editor.Ffi.Document.markerRaw : @& Document → UInt64 → IO RawWords`
lean_obj_res editor_glue_document_marker(b_lean_obj_arg document, uint64_t id) {
  editor_ffi_raw_words raw;
  editor_ffi_document_marker(lean_get_external_data(document), id, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.Document.placeRaw : @& Document → UInt64 → @& ByteArray → IO
// UInt64`
lean_obj_res editor_glue_document_place(b_lean_obj_arg document, uint64_t id,
                                        b_lean_obj_arg words) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_document_place(
      lean_get_external_data(document), id, byte_array_bytes(words),
      byte_array_len(words))));
}

// `Editor.Ffi.Document.unmark : @& Document → UInt64 → IO Bool`
lean_obj_res editor_glue_document_unmark(b_lean_obj_arg document, uint64_t id) {
  return lean_io_result_mk_ok(lean_box(
      editor_ffi_document_unmark(lean_get_external_data(document), id)));
}

// `Editor.Ffi.Snapshot.extentsRaw : @& Snapshot → @& ByteArray → IO RawWords`
lean_obj_res editor_glue_snapshot_extents(b_lean_obj_arg snapshot,
                                          b_lean_obj_arg words) {
  editor_ffi_raw_words raw;
  editor_ffi_snapshot_extents(lean_get_external_data(snapshot),
                              byte_array_bytes(words), byte_array_len(words),
                              &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// ---- A document's kept inverses ----
//
// A run of revisions and an origin go to the library as numbers, and what
// applying the run's inverse did comes back as words: a revision, and the
// selection handed back if there is one. Dropping kept inverses answers with
// a `bool`, as forgetting the log does.

void editor_ffi_document_apply_inverse(const editor_ffi_document *document,
                                       uint64_t first, uint64_t last,
                                       uint64_t origin,
                                       editor_ffi_raw_words *out);
bool editor_ffi_document_drop_inverses(const editor_ffi_document *document,
                                       uint64_t first, uint64_t last);

// `Editor.Ffi.Document.applyInverseRaw : @& Document → UInt64 → UInt64 →
// UInt64 → IO RawWords`
lean_obj_res editor_glue_document_apply_inverse(b_lean_obj_arg document,
                                                uint64_t first, uint64_t last,
                                                uint64_t origin) {
  editor_ffi_raw_words raw;
  editor_ffi_document_apply_inverse(lean_get_external_data(document), first,
                                    last, origin, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.Document.dropInverses : @& Document → UInt64 → UInt64 → IO Bool`
lean_obj_res editor_glue_document_drop_inverses(b_lean_obj_arg document,
                                                uint64_t first, uint64_t last) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_document_drop_inverses(
      lean_get_external_data(document), first, last)));
}

// ---- Fuzzy ranking ----
//
// The example of a list of strings crossing. The candidates go to the
// library as words, their count and then the byte length of each, and as one
// string of all of them end to end, both borrowed for the call; the ranking
// comes back as words. The call keeps nothing in the library.

void editor_ffi_fuzzy_rank(const uint8_t *pattern, size_t pattern_len,
                           const uint8_t *words, size_t words_len,
                           const uint8_t *strings, size_t strings_len,
                           editor_ffi_raw_words *out);

// `Editor.Ffi.fuzzyRankRaw : @& String → @& ByteArray → @& String →
// IO RawWords`
lean_obj_res editor_glue_fuzzy_rank(b_lean_obj_arg pattern,
                                    b_lean_obj_arg words,
                                    b_lean_obj_arg strings) {
  editor_ffi_raw_words raw;
  editor_ffi_fuzzy_rank(string_bytes(pattern), string_len(pattern),
                        byte_array_bytes(words), byte_array_len(words),
                        string_bytes(strings), string_len(strings), &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// ---- The event queues ----
//
// Rust threads push events and Lean pulls them: nothing here calls Lean. A
// queue is named by the tag of Lean's `Editor.Ffi.Queue`, which the library
// checks.

// The library's `RawEvent`.
typedef struct {
  uint64_t source_kind;
  uint64_t source_id;
  uint64_t kind;
  uint64_t code;
  uint64_t stamp;
  uint8_t *text;
  size_t text_len;
  uint8_t *words;
  size_t words_len;
} editor_ffi_raw_event;
bool editor_ffi_events_post(uint8_t queue, uint64_t source_id, uint64_t code,
                            const uint8_t *text, size_t text_len);
bool editor_ffi_events_next(uint8_t queue, editor_ffi_raw_event *out);
void editor_ffi_events_quit(void);
uint64_t editor_ffi_events_waiting(uint8_t queue);
bool editor_ffi_events_script_feed(uint8_t queue, uint64_t source_id,
                                   uint64_t count);

// `Editor.Ffi.postEvent : Queue → UInt64 → UInt64 → @& String → IO Bool`
lean_obj_res editor_glue_events_post(uint8_t queue, uint64_t source_id,
                                     uint64_t code, b_lean_obj_arg text) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_events_post(
      queue, source_id, code, string_bytes(text), string_len(text))));
}

// `Editor.Ffi.nextRaw : Queue → IO RawEvent`. Blocks in Rust until the queue
// has an event.
lean_obj_res editor_glue_events_next(uint8_t queue) {
  editor_ffi_raw_event raw;
  if (!editor_ffi_events_next(queue, &raw)) {
    return lean_io_result_mk_error(lean_mk_io_user_error(
        lean_mk_string("the Rust library knows no such event queue")));
  }
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  lean_object *words = byte_array_copy(raw.words, raw.words_len);
  editor_ffi_text_free(raw.words, raw.words_len);
  // `RawEvent`: `text` and `words`, then `sourceKind`, `sourceId`, `kind`,
  // `code` and `stamp`.
  lean_object *event = lean_alloc_ctor(0, 2, 5 * sizeof(uint64_t));
  lean_ctor_set(event, 0, text);
  lean_ctor_set(event, 1, words);
  lean_ctor_set_uint64(event, uint64_field(2, 0), raw.source_kind);
  lean_ctor_set_uint64(event, uint64_field(2, 1), raw.source_id);
  lean_ctor_set_uint64(event, uint64_field(2, 2), raw.kind);
  lean_ctor_set_uint64(event, uint64_field(2, 3), raw.code);
  lean_ctor_set_uint64(event, uint64_field(2, 4), raw.stamp);
  return lean_io_result_mk_ok(event);
}

// `Editor.Ffi.quit : IO Unit`
lean_obj_res editor_glue_events_quit(void) {
  editor_ffi_events_quit();
  return lean_io_result_mk_ok(lean_box(0));
}

// `Editor.Ffi.waiting : Queue → IO UInt64`
lean_obj_res editor_glue_events_waiting(uint8_t queue) {
  return lean_io_result_mk_ok(
      lean_box_uint64(editor_ffi_events_waiting(queue)));
}

// `Editor.Ffi.feedScript : Queue → UInt64 → UInt64 → IO Bool`
lean_obj_res editor_glue_events_script_feed(uint8_t queue, uint64_t source_id,
                                            uint64_t count) {
  return lean_io_result_mk_ok(
      lean_box(editor_ffi_events_script_feed(queue, source_id, count)));
}

// ---- The timer service ----
//
// The first service behind the completion queue. A request goes in as an id
// and a deadline, both plain numbers, and its completion comes back as an
// event on the completion queue, pulled like any other: nothing here calls
// Lean, and no handle crosses.

uint64_t editor_ffi_timers_now(void);
bool editor_ffi_timers_start(uint64_t id, uint64_t deadline);
bool editor_ffi_timers_cancel(uint64_t id);
uint64_t editor_ffi_timers_pending(void);

// `Editor.Ffi.timersNow : IO UInt64`
lean_obj_res editor_glue_timers_now(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_timers_now()));
}

// `Editor.Ffi.timersStart : UInt64 → UInt64 → IO Bool`
lean_obj_res editor_glue_timers_start(uint64_t id, uint64_t deadline) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_timers_start(id, deadline)));
}

// `Editor.Ffi.timersCancel : UInt64 → IO Bool`
lean_obj_res editor_glue_timers_cancel(uint64_t id) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_timers_cancel(id)));
}

// `Editor.Ffi.timersPending : IO UInt64`
lean_obj_res editor_glue_timers_pending(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_timers_pending()));
}

// ---- The file service ----
//
// The second service behind the completion queue. A request goes in as an
// id, a path (the bytes of a Lean string, borrowed for the call) and plain
// numbers; a save also borrows a snapshot handle, which the library clones.
// Its completion comes back as an event on the completion queue, like a
// timer's, and its result is then taken by the id, as one record: a status,
// a snapshot handle the caller owns (for a load that succeeded), words and a
// detail string.

// The library's `RawExpect`.
typedef struct {
  uint64_t tag;
  uint64_t seconds;
  uint64_t nanoseconds;
  uint64_t size;
} editor_ffi_raw_expect;
// The library's `RawFileResult`.
typedef struct {
  uint64_t status;
  editor_ffi_snapshot *snapshot;
  uint8_t *words;
  size_t words_len;
  uint8_t *detail;
  size_t detail_len;
} editor_ffi_raw_file_result;
bool editor_ffi_files_load(uint64_t id, const uint8_t *path, size_t path_len,
                           uint64_t limit);
bool editor_ffi_files_save(uint64_t id, const editor_ffi_snapshot *snapshot,
                           const uint8_t *path, size_t path_len,
                           const editor_ffi_raw_expect *expect);
bool editor_ffi_files_stamp(uint64_t id, const uint8_t *path, size_t path_len);
bool editor_ffi_files_take(uint64_t id, editor_ffi_raw_file_result *out);
bool editor_ffi_files_cancel(uint64_t id);
uint64_t editor_ffi_files_pending(void);

// `Editor.Ffi.filesLoad : UInt64 → @& String → UInt64 → IO Bool`
lean_obj_res editor_glue_files_load(uint64_t id, b_lean_obj_arg path,
                                    uint64_t limit) {
  return lean_io_result_mk_ok(lean_box(
      editor_ffi_files_load(id, string_bytes(path), string_len(path), limit)));
}

// `Editor.Ffi.filesStamp : UInt64 → @& String → IO Bool`
lean_obj_res editor_glue_files_stamp(uint64_t id, b_lean_obj_arg path) {
  return lean_io_result_mk_ok(lean_box(
      editor_ffi_files_stamp(id, string_bytes(path), string_len(path))));
}

// `Editor.Ffi.filesSaveRaw : UInt64 → @& Snapshot → @& String → UInt64 →
// UInt64 → UInt64 → UInt64 → IO Bool`. What the save expects arrives as four
// scalars and goes to the library as one record, by pointer.
lean_obj_res editor_glue_files_save(uint64_t id, b_lean_obj_arg snapshot,
                                    b_lean_obj_arg path, uint64_t tag,
                                    uint64_t seconds, uint64_t nanoseconds,
                                    uint64_t size) {
  editor_ffi_raw_expect expect = {
      .tag = tag, .seconds = seconds, .nanoseconds = nanoseconds, .size = size};
  return lean_io_result_mk_ok(lean_box(
      editor_ffi_files_save(id, lean_get_external_data(snapshot),
                            string_bytes(path), string_len(path), &expect)));
}

// `Editor.Ffi.filesTakeRaw : UInt64 → IO (Option RawFileResult)`. `none`
// when the service keeps no result for the id. A snapshot in the record
// becomes a Lean handle here, so its finaliser is what frees it.
lean_obj_res editor_glue_files_take(uint64_t id) {
  editor_ffi_raw_file_result raw;
  if (!editor_ffi_files_take(id, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  lean_object *snapshot = lean_box(0); // `none`
  if (raw.snapshot != NULL) {
    pthread_once(&snapshot_class_once, snapshot_class_register);
    snapshot = option_some(lean_alloc_external(snapshot_class, raw.snapshot));
  }
  lean_object *detail =
      lean_mk_string_from_bytes((const char *)raw.detail, raw.detail_len);
  // `RawFileResult`: the object fields `snapshot`, `words` and `detail`, then
  // `status`.
  lean_object *result = lean_alloc_ctor(0, 3, sizeof(uint64_t));
  lean_ctor_set(result, 0, snapshot);
  lean_ctor_set(result, 1, byte_array_copy(raw.words, raw.words_len));
  lean_ctor_set(result, 2, detail);
  lean_ctor_set_uint64(result, uint64_field(3, 0), raw.status);
  editor_ffi_text_free(raw.words, raw.words_len);
  editor_ffi_text_free(raw.detail, raw.detail_len);
  return lean_io_result_mk_ok(option_some(result));
}

// `Editor.Ffi.filesCancel : UInt64 → IO Bool`
lean_obj_res editor_glue_files_cancel(uint64_t id) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_files_cancel(id)));
}

// `Editor.Ffi.filesPending : IO UInt64`
lean_obj_res editor_glue_files_pending(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_files_pending()));
}

// ---- The process service ----
//
// The third service behind the completion queue. A run goes in with an id,
// the command as words and one string of every text it holds (borrowed for
// the call), as a list of strings does. Its completion comes back as an event
// on the completion queue, and its result is then taken by the id, as one
// record: a status, words, a detail string and the two streams' bytes, each
// a buffer the library lends and the glue hands back once copied.

// The library's `RawProcessResult`. `stdout` and `stderr` are names the C
// library takes, so the two streams' fields are named `out` and `err` here;
// only the layout has to match.
typedef struct {
  uint64_t status;
  uint8_t *words;
  size_t words_len;
  uint8_t *detail;
  size_t detail_len;
  uint8_t *out;
  size_t out_len;
  uint8_t *err;
  size_t err_len;
} editor_ffi_raw_process_result;
bool editor_ffi_processes_run(uint64_t id, const uint8_t *words,
                              size_t words_len, const uint8_t *strings,
                              size_t strings_len);
bool editor_ffi_processes_take(uint64_t id, editor_ffi_raw_process_result *out);
bool editor_ffi_processes_cancel(uint64_t id);
uint64_t editor_ffi_processes_pending(void);
void editor_ffi_processes_shutdown(void);
bool editor_ffi_processes_open(uint64_t id, const uint8_t *words,
                               size_t words_len, const uint8_t *strings,
                               size_t strings_len);
bool editor_ffi_processes_read(uint64_t child, uint64_t wait);
bool editor_ffi_processes_write(uint64_t child, uint64_t wait,
                                const uint8_t *bytes, size_t len);
bool editor_ffi_processes_close_input(uint64_t child, uint64_t wait);
bool editor_ffi_processes_take_stream(uint64_t wait,
                                      editor_ffi_raw_process_result *out);
uint64_t editor_ffi_processes_held(uint64_t child);

// `Editor.Ffi.processesRunRaw : UInt64 → @& ByteArray → @& String → IO Bool`
lean_obj_res editor_glue_processes_run(uint64_t id, b_lean_obj_arg words,
                                       b_lean_obj_arg strings) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_processes_run(
      id, byte_array_bytes(words), byte_array_len(words), string_bytes(strings),
      string_len(strings))));
}

// The Lean `RawProcessResult` of a record the library filled, as
// `option_some`'s argument, with the library's buffers handed back.
static lean_object *process_result_of(editor_ffi_raw_process_result raw) {
  lean_object *detail =
      lean_mk_string_from_bytes((const char *)raw.detail, raw.detail_len);
  // `RawProcessResult`: the object fields `words`, `detail`, `stdout` and
  // `stderr`, then `status`.
  lean_object *result = lean_alloc_ctor(0, 4, sizeof(uint64_t));
  lean_ctor_set(result, 0, byte_array_copy(raw.words, raw.words_len));
  lean_ctor_set(result, 1, detail);
  lean_ctor_set(result, 2, byte_array_copy(raw.out, raw.out_len));
  lean_ctor_set(result, 3, byte_array_copy(raw.err, raw.err_len));
  lean_ctor_set_uint64(result, uint64_field(4, 0), raw.status);
  editor_ffi_text_free(raw.words, raw.words_len);
  editor_ffi_text_free(raw.detail, raw.detail_len);
  editor_ffi_text_free(raw.out, raw.out_len);
  editor_ffi_text_free(raw.err, raw.err_len);
  return result;
}

// `Editor.Ffi.processesTakeRaw : UInt64 → IO (Option RawProcessResult)`.
// `none` when the service keeps no result for the id.
lean_obj_res editor_glue_processes_take(uint64_t id) {
  editor_ffi_raw_process_result raw;
  if (!editor_ffi_processes_take(id, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(option_some(process_result_of(raw)));
}

// `Editor.Ffi.processesOpenRaw : UInt64 → @& ByteArray → @& String → IO
// Bool`: a streaming child's open, laid out as a run is with three words
// before.
lean_obj_res editor_glue_processes_open(uint64_t id, b_lean_obj_arg words,
                                        b_lean_obj_arg strings) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_processes_open(
      id, byte_array_bytes(words), byte_array_len(words), string_bytes(strings),
      string_len(strings))));
}

// `Editor.Ffi.processesRead : UInt64 → UInt64 → IO Bool`
lean_obj_res editor_glue_processes_read(uint64_t child, uint64_t wait) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_processes_read(child, wait)));
}

// `Editor.Ffi.processesWrite : UInt64 → UInt64 → @& ByteArray → IO Bool`.
// The library copies the bytes, which are borrowed for the call.
lean_obj_res editor_glue_processes_write(uint64_t child, uint64_t wait,
                                         b_lean_obj_arg bytes) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_processes_write(
      child, wait, byte_array_bytes(bytes), byte_array_len(bytes))));
}

// `Editor.Ffi.processesCloseInput : UInt64 → UInt64 → IO Bool`
lean_obj_res editor_glue_processes_close_input(uint64_t child, uint64_t wait) {
  return lean_io_result_mk_ok(
      lean_box(editor_ffi_processes_close_input(child, wait)));
}

// `Editor.Ffi.processesTakeStreamRaw : UInt64 → IO (Option
// RawProcessResult)`. A reply about a streaming child crosses in a run's
// record; Lean reads its lines off the lengths in its words.
lean_obj_res editor_glue_processes_take_stream(uint64_t wait) {
  editor_ffi_raw_process_result raw;
  if (!editor_ffi_processes_take_stream(wait, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  return lean_io_result_mk_ok(option_some(process_result_of(raw)));
}

// `Editor.Ffi.processesHeld : UInt64 → IO UInt64`
lean_obj_res editor_glue_processes_held(uint64_t child) {
  return lean_io_result_mk_ok(
      lean_box_uint64(editor_ffi_processes_held(child)));
}

// `Editor.Ffi.processesCancel : UInt64 → IO Bool`. It kills the run's
// process group in the library.
lean_obj_res editor_glue_processes_cancel(uint64_t id) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_processes_cancel(id)));
}

// `Editor.Ffi.processesPending : IO UInt64`
lean_obj_res editor_glue_processes_pending(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_processes_pending()));
}

// `Editor.Ffi.processesShutdown : IO Unit`. Blocks in Rust until every child
// the service started has been reaped.
lean_obj_res editor_glue_processes_shutdown(void) {
  editor_ffi_processes_shutdown();
  return lean_io_result_mk_ok(lean_box(0));
}

// ---- The watch service ----
//
// The fourth service behind the completion queue. A start goes in with an
// id, three words and the path's bytes (both borrowed for the call). Its
// completion comes back on the completion queue, and its reply is then
// taken by the id; a read is a wait of its own, its delivery taken the same
// way, as one record: a status, words, a detail and the paths end to end,
// each a buffer the library lends and the glue hands back once copied.

// The library's `RawWatchReply`.
typedef struct {
  uint64_t status;
  uint8_t *words;
  size_t words_len;
  uint8_t *detail;
  size_t detail_len;
  uint8_t *paths;
  size_t paths_len;
} editor_ffi_raw_watch_reply;
bool editor_ffi_watches_start(uint64_t id, const uint8_t *words,
                              size_t words_len, const uint8_t *path,
                              size_t path_len);
bool editor_ffi_watches_next(uint64_t watch, uint64_t wait);
bool editor_ffi_watches_take(uint64_t wait, editor_ffi_raw_watch_reply *out);
bool editor_ffi_watches_cancel(uint64_t id);
uint64_t editor_ffi_watches_pending(void);
void editor_ffi_watches_shutdown(void);

// `Editor.Ffi.watchesStartRaw : UInt64 → @& ByteArray → @& String → IO Bool`
lean_obj_res editor_glue_watches_start(uint64_t id, b_lean_obj_arg words,
                                       b_lean_obj_arg path) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_watches_start(
      id, byte_array_bytes(words), byte_array_len(words), string_bytes(path),
      string_len(path))));
}

// `Editor.Ffi.watchesNext : UInt64 → UInt64 → IO Bool`
lean_obj_res editor_glue_watches_next(uint64_t watch, uint64_t wait) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_watches_next(watch, wait)));
}

// `Editor.Ffi.watchesTakeRaw : UInt64 → IO (Option RawWatchReply)`. `none`
// when the service keeps nothing for the wait.
lean_obj_res editor_glue_watches_take(uint64_t wait) {
  editor_ffi_raw_watch_reply raw;
  if (!editor_ffi_watches_take(wait, &raw)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  lean_object *detail =
      lean_mk_string_from_bytes((const char *)raw.detail, raw.detail_len);
  // `RawWatchReply`: the object fields `words`, `detail` and `paths`, then
  // `status`.
  lean_object *reply = lean_alloc_ctor(0, 3, sizeof(uint64_t));
  lean_ctor_set(reply, 0, byte_array_copy(raw.words, raw.words_len));
  lean_ctor_set(reply, 1, detail);
  lean_ctor_set(reply, 2, byte_array_copy(raw.paths, raw.paths_len));
  lean_ctor_set_uint64(reply, uint64_field(3, 0), raw.status);
  editor_ffi_text_free(raw.words, raw.words_len);
  editor_ffi_text_free(raw.detail, raw.detail_len);
  editor_ffi_text_free(raw.paths, raw.paths_len);
  return lean_io_result_mk_ok(option_some(reply));
}

// `Editor.Ffi.watchesCancel : UInt64 → IO Bool`
lean_obj_res editor_glue_watches_cancel(uint64_t id) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_watches_cancel(id)));
}

// `Editor.Ffi.watchesPending : IO UInt64`
lean_obj_res editor_glue_watches_pending(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_watches_pending()));
}

// `Editor.Ffi.watchesShutdown : IO Unit`. Returns once every watch is ended
// and every start in flight has returned.
lean_obj_res editor_glue_watches_shutdown(void) {
  editor_ffi_watches_shutdown();
  return lean_io_result_mk_ok(lean_box(0));
}

// ---- The window ----
//
// Running the window is one blocking call: the library's main-thread service
// runs the window's loop, and the call returns when Lean has closed the
// window from another thread. What the window reports arrives as events on
// the editor queue. A platform is named by the tag of Lean's
// `Editor.Ffi.Platform`, which the library checks.

// The library's `RawRefusal`.
typedef struct {
  uint8_t *reason;
  size_t reason_len;
} editor_ffi_raw_refusal;
uint8_t editor_ffi_window_run(uint8_t platform, bool composition,
                              uint8_t title_bar, uint8_t present_mode,
                              uint32_t frame_latency,
                              editor_ffi_raw_refusal *out);
bool editor_ffi_window_close(uint8_t platform);
bool editor_ffi_window_request(uint8_t platform, uint8_t request);
uint64_t editor_ffi_input_clock_now(void);
bool editor_ffi_window_post_input(uint8_t kind, uint64_t code,
                                  const uint8_t *text, size_t text_len,
                                  const uint8_t *words, size_t words_len);

// `Editor.Ffi.windowRunRaw : Platform → Bool → TitleBar → UInt8 → UInt32 →
// IO RawWindowRun`. Blocks in Rust until the window has closed. The status
// is the library's: 0 when the window ran and something drew in it, with an
// empty reason; 1 when no window ran and 2 when nothing drew in the window,
// each with the reason. The title bar is the tag of Lean's `TitleBar`, and
// the present mode's tag and the frame latency are each 0 for none asked.
lean_obj_res editor_glue_window_run(uint8_t platform, uint8_t composition,
                                    uint8_t title_bar, uint8_t present_mode,
                                    uint32_t frame_latency) {
  editor_ffi_raw_refusal refusal;
  uint8_t status = editor_ffi_window_run(platform, composition, title_bar,
                                         present_mode, frame_latency, &refusal);
  lean_object *reason;
  if (status == 0) {
    reason = lean_mk_string("");
  } else {
    reason = lean_mk_string_from_bytes((const char *)refusal.reason,
                                       refusal.reason_len);
    editor_ffi_text_free(refusal.reason, refusal.reason_len);
  }
  lean_object *run = lean_alloc_ctor(0, 1, sizeof(uint64_t));
  lean_ctor_set(run, 0, reason);
  lean_ctor_set_uint64(run, uint64_field(1, 0), status);
  return lean_io_result_mk_ok(run);
}

// `Editor.Ffi.windowClose : Platform → IO Unit`. The library returns whether
// the tag names a platform, which a tag from Lean's `Platform` always does.
lean_obj_res editor_glue_window_close(uint8_t platform) {
  editor_ffi_window_close(platform);
  return lean_io_result_mk_ok(lean_box(0));
}

// `Editor.Ffi.windowRequest : Platform → WindowRequest → IO Unit`. The library
// returns whether both tags name something, which tags from Lean's `Platform`
// and `WindowRequest` always do.
lean_obj_res editor_glue_window_request(uint8_t platform, uint8_t request) {
  editor_ffi_window_request(platform, request);
  return lean_io_result_mk_ok(lean_box(0));
}

// `Editor.Ffi.inputClock : IO UInt64`
lean_obj_res editor_glue_input_clock(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_input_clock_now()));
}

// `Editor.Ffi.postInputRaw : EventKind → UInt64 → @& String → @& ByteArray →
// IO Bool`. The kind is the tag of Lean's `EventKind`, which the library
// checks.
lean_obj_res editor_glue_window_post_input(uint8_t kind, uint64_t code,
                                           b_lean_obj_arg text,
                                           b_lean_obj_arg words) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_window_post_input(
      kind, code, string_bytes(text), string_len(text), byte_array_bytes(words),
      byte_array_len(words))));
}

// ---- The interrupt flag ----
//
// The library raises a flag as the interrupt key arrives on the editor queue,
// before the key is queued. Lean tells it which key that is, asks the flag,
// and lowers it. None of these blocks.

bool editor_ffi_interrupt_key_set(const uint8_t *words, size_t words_len);
void editor_ffi_interrupt_key_clear(void);
bool editor_ffi_interrupt_raised(void);
void editor_ffi_interrupt_lower(void);

// `Editor.Ffi.interruptKeySetRaw : @& ByteArray → IO Bool`. The words are
// borrowed for the call.
lean_obj_res editor_glue_interrupt_key_set(b_lean_obj_arg words) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_interrupt_key_set(
      byte_array_bytes(words), byte_array_len(words))));
}

// `Editor.Ffi.interruptKeyClear : IO Unit`
lean_obj_res editor_glue_interrupt_key_clear(void) {
  editor_ffi_interrupt_key_clear();
  return lean_io_result_mk_ok(lean_box(0));
}

// `Editor.Ffi.interruptRaised : IO Bool`
lean_obj_res editor_glue_interrupt_raised(void) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_interrupt_raised()));
}

// `Editor.Ffi.interruptLower : IO Unit`
lean_obj_res editor_glue_interrupt_lower(void) {
  editor_ffi_interrupt_lower();
  return lean_io_result_mk_ok(lean_box(0));
}

// ---- The display ----
//
// The fourth handle: layout, which lays out the text of snapshots and answers
// the layout queries about them. A query takes a snapshot handle and whole
// numbers, and comes back as words, as a document's log does.

// The Rust library's display.
typedef struct editor_ffi_display editor_ffi_display;
editor_ffi_display *editor_ffi_display_new_cells(uint64_t advance,
                                                 uint64_t line_height);
void editor_ffi_display_rows(const editor_ffi_display *display,
                             const editor_ffi_snapshot *snapshot,
                             uint64_t width, uint64_t height, uint64_t across,
                             uint64_t down, uint64_t top, size_t anchor,
                             editor_ffi_raw_words *out);
void editor_ffi_display_move(const editor_ffi_display *display,
                             const editor_ffi_snapshot *snapshot,
                             uint64_t width, uint64_t across, size_t position,
                             int64_t lines, bool goal_present, uint64_t goal,
                             editor_ffi_raw_words *out);
bool editor_ffi_display_publish(const editor_ffi_display *display,
                                const uint8_t *words, size_t words_len,
                                const uint8_t *strings, size_t strings_len,
                                const editor_ffi_snapshot *const *snapshots,
                                size_t count);
bool editor_ffi_display_define(const editor_ffi_display *display,
                               const uint8_t *words, size_t words_len,
                               const uint8_t *strings, size_t strings_len);
void editor_ffi_display_frame_text(const editor_ffi_display *display,
                                   editor_ffi_raw_text *out);
void editor_ffi_display_frame_rows(const editor_ffi_display *display,
                                   uint64_t view, editor_ffi_raw_words *out);
void editor_ffi_display_scene(const editor_ffi_display *display,
                              editor_ffi_raw_words *words,
                              editor_ffi_raw_text *strings);
void editor_ffi_display_free(editor_ffi_display *display);
uint64_t editor_ffi_display_live(void);

static lean_external_class *display_class;
static pthread_once_t display_class_once = PTHREAD_ONCE_INIT;

// Runs when Lean drops the last reference to a display, on whichever thread
// dropped it.
static void display_finalize(void *display) {
  editor_ffi_display_free(display);
}

// A display holds no Lean objects, so there is nothing to visit.
static void display_foreach(void *display, b_lean_obj_arg visitor) {
  (void)display;
  (void)visitor;
}

static void display_class_register(void) {
  display_class =
      lean_register_external_class(display_finalize, display_foreach);
}

// `Editor.Ffi.Display.newCells : UInt64 → UInt64 → IO Display`
lean_obj_res editor_glue_display_new_cells(uint64_t advance,
                                           uint64_t line_height) {
  pthread_once(&display_class_once, display_class_register);
  return lean_io_result_mk_ok(lean_alloc_external(
      display_class, editor_ffi_display_new_cells(advance, line_height)));
}

// `Editor.Ffi.Display.live : IO UInt64`
lean_obj_res editor_glue_display_live(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_display_live()));
}

// `Editor.Ffi.Display.rowsRaw : @& Display → @& Snapshot → UInt64 → UInt64 →
// UInt64 → UInt64 → UInt64 → USize → IO RawWords`
lean_obj_res editor_glue_display_rows(b_lean_obj_arg display,
                                      b_lean_obj_arg snapshot, uint64_t width,
                                      uint64_t height, uint64_t across,
                                      uint64_t down, uint64_t top,
                                      size_t anchor) {
  editor_ffi_raw_words raw;
  editor_ffi_display_rows(lean_get_external_data(display),
                          lean_get_external_data(snapshot), width, height,
                          across, down, top, anchor, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.Display.moveRaw : @& Display → @& Snapshot → UInt64 → UInt64 →
// USize → UInt64 → Bool → UInt64 → IO RawWords`. The lines are a two's
// complement number in a `UInt64`.
lean_obj_res editor_glue_display_move(b_lean_obj_arg display,
                                      b_lean_obj_arg snapshot, uint64_t width,
                                      uint64_t across, size_t position,
                                      uint64_t lines, uint8_t goal_present,
                                      uint64_t goal) {
  editor_ffi_raw_words raw;
  editor_ffi_display_move(lean_get_external_data(display),
                          lean_get_external_data(snapshot), width, across,
                          position, (int64_t)lines, goal_present, goal, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.Display.publishRaw : @& Display → @& ByteArray → @& String →
// @& Array Snapshot → IO Bool`. The snapshots go to Rust as a C array of
// their pointers, made here for the call: a list of handles.
lean_obj_res editor_glue_display_publish(b_lean_obj_arg display,
                                         b_lean_obj_arg words,
                                         b_lean_obj_arg strings,
                                         b_lean_obj_arg snapshots) {
  size_t count = lean_array_size(snapshots);
  const editor_ffi_snapshot **handles = NULL;
  if (count != 0) {
    handles = malloc(count * sizeof *handles);
    if (handles == NULL) {
      return lean_io_result_mk_ok(lean_box(false));
    }
    for (size_t index = 0; index < count; index++) {
      handles[index] =
          lean_get_external_data(lean_array_get_core(snapshots, index));
    }
  }
  bool published = editor_ffi_display_publish(
      lean_get_external_data(display), byte_array_bytes(words),
      byte_array_len(words), string_bytes(strings), string_len(strings),
      handles, count);
  free(handles);
  return lean_io_result_mk_ok(lean_box(published));
}

// `Editor.Ffi.Display.defineRaw : @& Display → @& ByteArray → @& String →
// IO Bool`
lean_obj_res editor_glue_display_define(b_lean_obj_arg display,
                                        b_lean_obj_arg words,
                                        b_lean_obj_arg strings) {
  bool defined = editor_ffi_display_define(
      lean_get_external_data(display), byte_array_bytes(words),
      byte_array_len(words), string_bytes(strings), string_len(strings));
  return lean_io_result_mk_ok(lean_box(defined));
}

// `Editor.Ffi.Display.frameText : @& Display → IO String`
lean_obj_res editor_glue_display_frame_text(b_lean_obj_arg display) {
  editor_ffi_raw_text raw;
  editor_ffi_display_frame_text(lean_get_external_data(display), &raw);
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  return lean_io_result_mk_ok(text);
}

// `Editor.Ffi.Display.frameRowsRaw : @& Display → UInt64 → IO RawWords`
lean_obj_res editor_glue_display_frame_rows(b_lean_obj_arg display,
                                            uint64_t view) {
  editor_ffi_raw_words raw;
  editor_ffi_display_frame_rows(lean_get_external_data(display), view, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.Display.sceneRaw : @& Display → IO RawScene`
lean_obj_res editor_glue_display_scene(b_lean_obj_arg display) {
  editor_ffi_raw_words words;
  editor_ffi_raw_text strings;
  editor_ffi_display_scene(lean_get_external_data(display), &words, &strings);
  // `RawScene`: the object fields `words` and `strings`, then `status`.
  lean_object *scene = lean_alloc_ctor(0, 2, sizeof(uint64_t));
  lean_ctor_set(scene, 0, byte_array_copy(words.words, words.len));
  lean_ctor_set(
      scene, 1,
      lean_mk_string_from_bytes((const char *)strings.text, strings.text_len));
  lean_ctor_set_uint64(scene, uint64_field(2, 0), words.status);
  editor_ffi_text_free(words.words, words.len);
  editor_ffi_text_free(strings.text, strings.text_len);
  return lean_io_result_mk_ok(scene);
}

// ---- A display's picture, for tests ----
//
// A display over one font file it is given, and the picture of its latest
// frame, drawn by the library's CPU renderer; and a picture read from and
// written to a PNG file. A picture crosses as the library's `RawPicture`,
// which the glue builds into Lean's: its pixels copied into a `ByteArray`,
// and the library's buffer handed back.

// The library's `RawPicture`.
typedef struct {
  uint64_t width;
  uint64_t height;
  uint8_t *rgba;
  size_t len;
} editor_ffi_raw_picture;
editor_ffi_display *
editor_ffi_display_new_font(const uint8_t *bytes, size_t len,
                            const uint8_t *family, size_t family_len,
                            editor_ffi_raw_text *out_reason);
void editor_ffi_display_picture(const editor_ffi_display *display,
                                editor_ffi_raw_picture *out);
bool editor_ffi_picture_from_png(const uint8_t *bytes, size_t len,
                                 editor_ffi_raw_picture *out,
                                 editor_ffi_raw_text *out_reason);
bool editor_ffi_picture_to_png(uint64_t width, uint64_t height,
                               const uint8_t *rgba, size_t len,
                               editor_ffi_raw_words *out,
                               editor_ffi_raw_text *out_reason);

// Lean's `RawPicture` for a record the library filled: the object field
// `rgba`, then `width` and `height`. The library's buffer is handed back.
static lean_object *raw_picture_take(editor_ffi_raw_picture raw) {
  lean_object *picture = lean_alloc_ctor(0, 1, 2 * sizeof(uint64_t));
  lean_ctor_set(picture, 0, byte_array_copy(raw.rgba, raw.len));
  lean_ctor_set_uint64(picture, uint64_field(1, 0), raw.width);
  lean_ctor_set_uint64(picture, uint64_field(1, 1), raw.height);
  editor_ffi_text_free(raw.rgba, raw.len);
  return picture;
}

// The `IO` error of the library's reason, whose buffer is handed back.
static lean_obj_res reason_error(editor_ffi_raw_text reason) {
  lean_object *text =
      lean_mk_string_from_bytes((const char *)reason.text, reason.text_len);
  editor_ffi_text_free(reason.text, reason.text_len);
  return lean_io_result_mk_error(lean_mk_io_user_error(text));
}

// `Editor.Ffi.Display.newFont : @& ByteArray → @& String → IO Display`
lean_obj_res editor_glue_display_new_font(b_lean_obj_arg bytes,
                                          b_lean_obj_arg family) {
  pthread_once(&display_class_once, display_class_register);
  editor_ffi_raw_text reason;
  editor_ffi_display *display = editor_ffi_display_new_font(
      byte_array_bytes(bytes), byte_array_len(bytes), string_bytes(family),
      string_len(family), &reason);
  if (display == NULL) {
    return reason_error(reason);
  }
  editor_ffi_text_free(reason.text, reason.text_len);
  return lean_io_result_mk_ok(lean_alloc_external(display_class, display));
}

// `Editor.Ffi.Display.pictureRaw : @& Display → IO RawPicture`
lean_obj_res editor_glue_display_picture(b_lean_obj_arg display) {
  editor_ffi_raw_picture raw;
  editor_ffi_display_picture(lean_get_external_data(display), &raw);
  return lean_io_result_mk_ok(raw_picture_take(raw));
}

// `Editor.Ffi.Picture.ofPngRaw : @& ByteArray → IO RawPicture`
lean_obj_res editor_glue_picture_from_png(b_lean_obj_arg bytes) {
  editor_ffi_raw_picture raw;
  editor_ffi_raw_text reason;
  bool read = editor_ffi_picture_from_png(byte_array_bytes(bytes),
                                          byte_array_len(bytes), &raw, &reason);
  lean_object *picture = raw_picture_take(raw);
  if (!read) {
    lean_dec(picture);
    return reason_error(reason);
  }
  editor_ffi_text_free(reason.text, reason.text_len);
  return lean_io_result_mk_ok(picture);
}

// `Editor.Ffi.Picture.toPngRaw : UInt64 → UInt64 → @& ByteArray → IO
// ByteArray`
lean_obj_res editor_glue_picture_to_png(uint64_t width, uint64_t height,
                                        b_lean_obj_arg rgba) {
  editor_ffi_raw_words raw;
  editor_ffi_raw_text reason;
  bool written =
      editor_ffi_picture_to_png(width, height, byte_array_bytes(rgba),
                                byte_array_len(rgba), &raw, &reason);
  lean_object *png = byte_array_copy(raw.words, raw.len);
  editor_ffi_text_free(raw.words, raw.len);
  if (!written) {
    lean_dec(png);
    return reason_error(reason);
  }
  editor_ffi_text_free(reason.text, reason.text_len);
  return lean_io_result_mk_ok(png);
}

// ---- The display's binding to the presenter, and the render session ----
//
// A display bound to the library's presenter has its frames drawn by the
// render session that runs: the window's, or the headless mode's, which the
// library runs on a thread of its own. The journal and the counters are the
// latest session's, read after it has ended too.

editor_ffi_display *editor_ffi_display_new_system(void);
void editor_ffi_display_present(const editor_ffi_display *display);
void editor_ffi_display_heights(const editor_ffi_display *display,
                                editor_ffi_raw_words *out);
uint8_t editor_ffi_render_headless_start(editor_ffi_raw_text *out);
bool editor_ffi_render_headless_stop(void);
void editor_ffi_render_journal(uint64_t after, editor_ffi_raw_words *out);
void editor_ffi_render_counters(editor_ffi_raw_words *out);
uint8_t editor_ffi_render_resting(void);

// `Editor.Ffi.Display.newSystem : IO Display`
lean_obj_res editor_glue_display_new_system(void) {
  pthread_once(&display_class_once, display_class_register);
  return lean_io_result_mk_ok(
      lean_alloc_external(display_class, editor_ffi_display_new_system()));
}

// `Editor.Ffi.Display.present : @& Display → IO Unit`
lean_obj_res editor_glue_display_present(b_lean_obj_arg display) {
  editor_ffi_display_present(lean_get_external_data(display));
  return lean_io_result_mk_ok(lean_box(0));
}

// `Editor.Ffi.Display.heightsRaw : @& Display → IO RawWords`
lean_obj_res editor_glue_display_heights(b_lean_obj_arg display) {
  editor_ffi_raw_words raw;
  editor_ffi_display_heights(lean_get_external_data(display), &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.renderHeadlessRaw : IO RawRenderStart`: the object field
// `reason`, then `status`.
lean_obj_res editor_glue_render_headless(void) {
  editor_ffi_raw_text raw;
  uint8_t status = editor_ffi_render_headless_start(&raw);
  lean_object *reason =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  lean_object *started = lean_alloc_ctor(0, 1, sizeof(uint64_t));
  lean_ctor_set(started, 0, reason);
  lean_ctor_set_uint64(started, uint64_field(1, 0), status);
  return lean_io_result_mk_ok(started);
}

// `Editor.Ffi.renderStop : IO Bool`
lean_obj_res editor_glue_render_stop(void) {
  return lean_io_result_mk_ok(
      lean_box(editor_ffi_render_headless_stop() ? 1 : 0));
}

// `Editor.Ffi.renderJournalRaw : UInt64 → IO RawWords`
lean_obj_res editor_glue_render_journal(uint64_t after) {
  editor_ffi_raw_words raw;
  editor_ffi_render_journal(after, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.renderCountersRaw : IO RawWords`
lean_obj_res editor_glue_render_counters(void) {
  editor_ffi_raw_words raw;
  editor_ffi_render_counters(&raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// `Editor.Ffi.renderRestingRaw : IO UInt8`
lean_obj_res editor_glue_render_resting(void) {
  return lean_io_result_mk_ok(lean_box(editor_ffi_render_resting()));
}

void editor_ffi_window_presentation(editor_ffi_raw_words *out);

// `Editor.Ffi.windowPresentationRaw : IO RawWords`
lean_obj_res editor_glue_window_presentation(void) {
  editor_ffi_raw_words raw;
  editor_ffi_window_presentation(&raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

void editor_ffi_window_asked(uint8_t platform, editor_ffi_raw_words *out);

// `Editor.Ffi.windowAskedRaw : Platform → IO RawWords`
lean_obj_res editor_glue_window_asked(uint8_t platform) {
  editor_ffi_raw_words raw;
  editor_ffi_window_asked(platform, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

void editor_ffi_window_opened_with(uint8_t platform, editor_ffi_raw_words *out);

// `Editor.Ffi.windowOpenedWithRaw : Platform → IO RawWords`
lean_obj_res editor_glue_window_opened_with(uint8_t platform) {
  editor_ffi_raw_words raw;
  editor_ffi_window_opened_with(platform, &raw);
  return lean_io_result_mk_ok(raw_words_take(raw));
}

// ---- The clipboard ----
//
// A clipboard handle is the library's, held by Lean as an external object
// freed by its finaliser, as a display is.

// The Rust library's clipboard.
typedef struct editor_ffi_clipboard editor_ffi_clipboard;
editor_ffi_clipboard *editor_ffi_clipboard_memory(void);
editor_ffi_clipboard *editor_ffi_clipboard_failing(const uint8_t *reason,
                                                   size_t reason_len);
editor_ffi_clipboard *editor_ffi_clipboard_system(editor_ffi_raw_text *out);
uint8_t editor_ffi_clipboard_read(const editor_ffi_clipboard *clipboard,
                                  editor_ffi_raw_text *out);
bool editor_ffi_clipboard_write(const editor_ffi_clipboard *clipboard,
                                const uint8_t *text, size_t text_len,
                                editor_ffi_raw_text *out);
void editor_ffi_clipboard_free(editor_ffi_clipboard *clipboard);
uint64_t editor_ffi_clipboard_live(void);

static lean_external_class *clipboard_class;
static pthread_once_t clipboard_class_once = PTHREAD_ONCE_INIT;

// Runs when Lean drops the last reference to a clipboard.
static void clipboard_finalize(void *clipboard) {
  editor_ffi_clipboard_free(clipboard);
}

// A clipboard holds no Lean objects, so there is nothing to visit.
static void clipboard_foreach(void *clipboard, b_lean_obj_arg visitor) {
  (void)clipboard;
  (void)visitor;
}

static void clipboard_class_register(void) {
  clipboard_class =
      lean_register_external_class(clipboard_finalize, clipboard_foreach);
}

// A Lean string of the text `raw` lends, its buffer handed back.
static lean_object *text_take(editor_ffi_raw_text raw) {
  lean_object *text =
      lean_mk_string_from_bytes((const char *)raw.text, raw.text_len);
  editor_ffi_text_free(raw.text, raw.text_len);
  return text;
}

// `Editor.Ffi.Clipboard.memory : IO Clipboard`
lean_obj_res editor_glue_clipboard_memory(void) {
  pthread_once(&clipboard_class_once, clipboard_class_register);
  return lean_io_result_mk_ok(
      lean_alloc_external(clipboard_class, editor_ffi_clipboard_memory()));
}

// `Editor.Ffi.Clipboard.failing : @& String → IO Clipboard`
lean_obj_res editor_glue_clipboard_failing(b_lean_obj_arg reason) {
  pthread_once(&clipboard_class_once, clipboard_class_register);
  return lean_io_result_mk_ok(lean_alloc_external(
      clipboard_class,
      editor_ffi_clipboard_failing(string_bytes(reason), string_len(reason))));
}

// `Editor.Ffi.Clipboard.system : IO (Except String Clipboard)`. `Except`'s
// `error` is constructor 0 and `ok` constructor 1.
lean_obj_res editor_glue_clipboard_system(void) {
  pthread_once(&clipboard_class_once, clipboard_class_register);
  editor_ffi_raw_text reason;
  editor_ffi_clipboard *clipboard = editor_ffi_clipboard_system(&reason);
  lean_object *result;
  if (clipboard == NULL) {
    result = lean_alloc_ctor(0, 1, 0);
    lean_ctor_set(result, 0, text_take(reason));
  } else {
    result = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(result, 0, lean_alloc_external(clipboard_class, clipboard));
  }
  return lean_io_result_mk_ok(result);
}

// `Editor.Ffi.Clipboard.readRaw : @& Clipboard → IO RawClipboardRead`:
// the object field `text`, then `status`.
lean_obj_res editor_glue_clipboard_read(b_lean_obj_arg clipboard) {
  editor_ffi_raw_text raw;
  uint8_t status =
      editor_ffi_clipboard_read(lean_get_external_data(clipboard), &raw);
  lean_object *read = lean_alloc_ctor(0, 1, sizeof(uint64_t));
  lean_ctor_set(read, 0, text_take(raw));
  lean_ctor_set_uint64(read, uint64_field(1, 0), status);
  return lean_io_result_mk_ok(read);
}

// `Editor.Ffi.Clipboard.write : @& Clipboard → @& String → IO (Option
// String)`: `none` when written, and `some` of the reason otherwise.
lean_obj_res editor_glue_clipboard_write(b_lean_obj_arg clipboard,
                                         b_lean_obj_arg text) {
  editor_ffi_raw_text reason;
  if (editor_ffi_clipboard_write(lean_get_external_data(clipboard),
                                 string_bytes(text), string_len(text),
                                 &reason)) {
    return lean_io_result_mk_ok(lean_box(0)); // `none`
  }
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, text_take(reason));
  return lean_io_result_mk_ok(some);
}

// `Editor.Ffi.Clipboard.live : IO UInt64`
lean_obj_res editor_glue_clipboard_live(void) {
  return lean_io_result_mk_ok(lean_box_uint64(editor_ffi_clipboard_live()));
}

// ---- The process entry point ----
//
// Lean's generated `main` runs the Lean `main` on a thread Lean creates, so
// Lean code is never on the process's main thread, and macOS only lets a
// window event loop run there. So `editor_entry` runs in place of `main`. It
// keeps the real main thread for the Rust library and runs Lean's unmodified
// `main` on a second thread. It knows nothing about how Lean initialises
// itself.
//
// How it comes to run in place of `main` is the linker's doing, and differs
// by platform (`linkArgs` in `lakefile.lean`):
//
// - macOS: `-Wl,-e,_editor_entry` makes `editor_entry` the entry point the
//   loader calls, and Lean's `main` keeps its name.
// - Linux: an ELF entry point is `_start`, which sets the C library up
//   before it calls `main`, so it must stay. `-Wl,--wrap=main` instead makes
//   every reference to `main` from another object, the C library's start-up
//   code among them, a reference to `__wrap_main`, and gives Lean's `main`
//   the name `__real_main`.

#if defined(__APPLE__)
// Lean's generated `main`.
int main(int argc, char **argv);
#define LEAN_MAIN main
#elif defined(__linux__)
// Lean's generated `main`, under the name `--wrap=main` gives it.
int __real_main(int argc, char **argv);
#define LEAN_MAIN __real_main
#else
#error "the entry point is written for macOS and Linux"
#endif

// Lean's runtime: sets the stack size of every thread Lean creates from now
// on (Lean's own main thread, dedicated tasks, the pool), to which the
// runtime adds 128 KiB. `lean.h` does not declare it; Lean's own `lean`
// binary calls it. It returns a boxed unit, which needs no release.
lean_obj_res lean_internal_set_thread_stack_size(size_t size);

// The stack of every thread Lean creates, so of every thread that runs
// config or elaborates it. Lean's default is a gigabyte, and the
// interpreter's stack check fires only once the stack is full: at this size
// a runaway recursion in config ends the process in milliseconds, and the
// elaborator still has ten times the deepest stack it was seen to use
// (`docs/design/lean-runtime.md`). It is set here, not through
// `LEAN_STACK_SIZE_KB` in the process's environment, which every child
// process would inherit. A user can still override it with that variable:
// Lean reads it when its `main` starts, after this.
#define LEAN_THREAD_STACK_SIZE ((size_t)64 << 20)

struct entry_args {
  int argc;
  char **argv;
};

// The stack of the thread that runs Lean's `main`. Lean runs the module
// initialisers on it. Left alone it would get the default for a second
// thread, 512 KiB, in place of the main thread's 8 MiB.
#define ENTRY_STACK_SIZE ((size_t)64 << 20)

// The stack size of the thread `run_lean_main` runs on, as the operating
// system reports it. Read back by `FfiTest`, and by nothing else.
static size_t entry_stack_size;

// `Editor.Ffi.entryStackSize : IO USize`
lean_obj_res editor_glue_entry_stack_size(void) {
  return lean_io_result_mk_ok(lean_box_usize(entry_stack_size));
}

// The stack size of the calling thread, as the operating system reports it;
// 0 if it does not say. macOS has one call for it. On Linux the size is read
// from the attributes glibc reports for a running thread.
static size_t thread_stack_size(void) {
#if defined(__APPLE__)
  return pthread_get_stacksize_np(pthread_self());
#elif defined(__linux__)
  pthread_attr_t attr;
  size_t size = 0;
  if (pthread_getattr_np(pthread_self(), &attr) != 0) {
    return 0;
  }
  if (pthread_attr_getstacksize(&attr, &size) != 0) {
    size = 0;
  }
  pthread_attr_destroy(&attr);
  return size;
#else
#error "the stack-size readout is written for macOS and Linux"
#endif
}

// `Editor.Ffi.threadStackSize : IO USize`. The stack size of the calling
// thread, as the operating system reports it.
lean_obj_res editor_glue_thread_stack_size(void) {
  return lean_io_result_mk_ok(lean_box_usize(thread_stack_size()));
}

// The second thread: runs Lean, and ends the process with Lean's exit status
// while the main thread is still parked.
static void *run_lean_main(void *arg) {
  struct entry_args *args = arg;
  entry_stack_size = thread_stack_size();
  exit(LEAN_MAIN(args->argc, args->argv));
}

int editor_entry(int argc, char **argv) {
  static struct entry_args args;
  args.argc = argc;
  args.argv = argv;

  // Open the service before Lean can ask it for anything.
  editor_ffi_main_thread_open();

  // Before Lean starts, so that it holds for the first thread Lean creates.
  lean_internal_set_thread_stack_size(LEAN_THREAD_STACK_SIZE);

  pthread_attr_t attr;
  pthread_t thread;
  if (pthread_attr_init(&attr) != 0 ||
      pthread_attr_setstacksize(&attr, ENTRY_STACK_SIZE) != 0 ||
      pthread_create(&thread, &attr, run_lean_main, &args) != 0) {
    fputs("editor: cannot start the thread that runs Lean\n", stderr);
    return 70;
  }
  editor_ffi_main_thread_serve();
}

#if defined(__linux__)
// What the C library's start-up code calls as `main` (see the top of this
// section).
int __wrap_main(int argc, char **argv) { return editor_entry(argc, argv); }
#endif
