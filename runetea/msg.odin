package runetea

import "core:fmt"
import "core:mem"
import "core:strings"

// Fixed-capacity, POD-safe carrier for a short string payload (error text,
// status lines, ...) inside a boxed Msg -- box()'s MESSAGE OWNERSHIP
// CONTRACT (arena.odin) forbids a bare `string` field, since a `string`
// points at a separate allocation box() knows nothing about. Msg_Text has no
// pointer fields at all (`is_pod_type(Msg_Text)` is true), so it may be
// embedded directly in any Msg type.
//
// Two accessors are provided, and they are NOT interchangeable:
//   - msg_text_string borrows `buf` -- fine for an immediate, same-expression
//     read (e.g. formatting it into a view string), unsafe to retain past the
//     call that produced the Msg_Text.
//   - msg_text_clone always allocates a fresh, independent copy -- the ONLY
//     safe choice for storing the text in a model field that outlives the
//     current Update call.
// Naming the borrowing one "_string" and the owning one "_clone" is the
// answer this design settled on for spike-findings.md addendum item 8's open
// question ("is there an Odin idiom -- a clone helper, a naming convention --
// that makes the copy obvious rather than remembered?"): "clone" says what it
// does without needing the doc comment. See the decision doc for the fuller
// discussion, including why the borrowing accessor is still offered at all
// rather than removed.
Msg_Text :: struct {
	buf: [MSG_TEXT_CAP]u8,
	len: u8,
}

MSG_TEXT_CAP :: 255

// Truncates silently past MSG_TEXT_CAP bytes rather than returning an error:
// Msg_Text exists to drop into a one-expression `return box(Err_Msg{reason =
// msg_text_from(...)}, ...)` inside a Cmd, and a fallible constructor would
// defeat that. Truncation is a real, measured cost of the POD design -- see
// the decision doc -- not a hidden one.
msg_text_from :: proc(s: string) -> Msg_Text {
	m: Msg_Text
	n := copy(m.buf[:], s)
	m.len = u8(n)
	return m
}

// Same truncation contract as msg_text_from, via fmt.bprintf into the fixed
// buffer -- no intermediate heap allocation the way fmt.aprintf would need.
msg_text_fmt :: proc(format: string, args: ..any) -> Msg_Text {
	m: Msg_Text
	s := fmt.bprintf(m.buf[:], format, ..args)
	m.len = u8(len(s))
	return m
}

// The ONLY way to get a `string` out of a Msg_Text, and it always allocates
// a fresh copy from `alloc` -- see the type's own doc comment for why that
// is load-bearing. Safe to call from `update` even though the Msg itself is
// freed by the loop moments after `update` returns: the returned string
// shares no storage with the Msg.
msg_text_clone :: proc(m: Msg_Text, alloc: mem.Allocator) -> string {
	m := m
	return strings.clone_from_bytes(m.buf[:m.len], alloc)
}

// BORROWS `m^`. Takes a POINTER, not a value, and that is load-bearing, not
// a style choice: an earlier version of this proc took `m: Msg_Text` by
// value and sliced ITS OWN local copy -- which put the returned string's
// data on this proc's own stack frame, dangling the instant it returned
// (caught live: the very first test that printed the result got back
// garbage). Passing `^Msg_Text` borrows the CALLER's storage instead, which
// is what makes the returned string valid for the rest of the caller's own
// expression/statement -- exactly the same shape of bug box()'s own doc
// comment warns about for `return v` vs `return p^`, just one level
// removed. Still unsafe to retain past that; use msg_text_clone to store it
// in a model field.
msg_text_string :: proc(m: ^Msg_Text) -> string {
	return string(m.buf[:m.len])
}
