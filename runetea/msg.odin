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
//
// READING ONE OUT OF A TYPE SWITCH -- the control structure every `update`
// uses, and the one place the two accessors behave differently:
//
//     switch v in msg {
//     case Err_Msg:
//         s := msg_text_clone(v.reason, alloc)     // works, allocates
//         r := v.reason                            // works, allocates nothing
//         t := msg_text_string(&r)                 // ... via a named copy
//         u := msg_text_string(&v.reason)          // DOES NOT COMPILE
//     }
//
// `Cannot take the pointer address of 'v.reason'`: Odin's `switch v in` binding
// is not addressable, so nothing can take its address or slice a fixed array
// out of it. That is not special to Msg_Text -- `v.buf[:v.n]` on ANY fixed-array
// field of ANY Msg fails the same way ("value is not addressable"), and the one
// line that fixes all of them is `vv := v` at the top of the case. Note the rule
// is specifically about `switch v in`: `if pm, ok := msg.(Err_Msg); ok` binds an
// ordinary local, and `&pm.reason` compiles there.
//
// THE SIGNATURE WAS RE-EXAMINED RATHER THAN JUST DOCUMENTED, and it stays as it
// is. Three alternatives were measured and all three are worse:
//   - `msg_text_string(m: Msg_Text)` -- taking the value. This is the version
//     that already existed once and was reverted; see this proc's own comment
//     below for the live failure. It cannot work: the returned string would
//     point into the callee's copy;
//   - `msg_text_string(#by_ptr m: Msg_Text)`, which would let the call site drop
//     the '&' entirely. TRIED: the syntax is accepted by this compiler, but the
//     parameter is still not addressable inside the proc, so `m.buf[:m.len]`
//     fails to compile and the idea dies at the definition, not the call;
//   - a new `msg_text_read(m: Msg_Text, into: ^[MSG_TEXT_CAP]u8) -> string`,
//     copying into caller storage. It compiles, but the call site needs a
//     255-byte scratch declaration -- strictly more code than the `r := v.reason`
//     line it would replace, for the same copy. Adding API that loses to the
//     workaround is not an improvement.
// So: `msg_text_clone` for one line (and inside `update` the allocator is the
// per-frame arena, so the copy costs a bump and is freed with the frame), or the
// two-line named copy when the allocation genuinely must not happen.
// test_msg_text_reads_out_of_a_type_switch_binding pins both spellings, so a
// future signature change that breaks them fails the suite instead of the user's
// build.
Msg_Text :: struct {
	buf: [MSG_TEXT_CAP]u8,
	len: u8,
	// Whether the text that went IN was longer than `buf` could hold, i.e.
	// whether what comes out is the whole story.
	//
	// TRUNCATION STAYS -- what changes is that it is no longer SILENT. The cap
	// is what makes this type POD (see the type comment), and a fallible
	// constructor would defeat the one-expression `return box(Err_Msg{reason =
	// msg_text_from(...)})` shape the type exists for. But "the payload was
	// clipped and nothing anywhere records that" is the failure shape this
	// codebase refuses everywhere else, so it is recorded here, in one byte,
	// and read back with msg_text_truncated.
	//
	// Still POD: a bool has no pointer in its field tree, so box() accepts a
	// Msg_Text exactly as it did before.
	truncated: bool,
}

// The most bytes a Msg_Text can carry. 255 rather than 256 because `len` is a
// u8 and 255 is the largest length it can express -- the buffer is sized to the
// counter, not the other way round.
//
// This is not a soft limit that grows: it is the whole reason the type is POD.
// A payload that genuinely needs more than 255 bytes needs a different design
// (a handle into application-owned storage), which v1.0 does not have -- see
// docs/LIMITATIONS.md.
MSG_TEXT_CAP :: 255

// Truncates past MSG_TEXT_CAP bytes rather than returning an error: Msg_Text
// exists to drop into a one-expression `return box(Err_Msg{reason =
// msg_text_from(...)}, ...)` inside a Cmd, and a fallible constructor would
// defeat that. Truncation is a real, measured cost of the POD design -- see the
// decision doc -- not a hidden one, and `truncated` is what stops it being a
// quiet one: msg_text_truncated(m) answers "is this the whole message?".
msg_text_from :: proc(s: string) -> Msg_Text {
	m: Msg_Text
	n := copy(m.buf[:], s)
	m.len = u8(n)
	m.truncated = len(s) > MSG_TEXT_CAP
	return m
}

// Same truncation contract as msg_text_from, via fmt.bprintf into a fixed
// buffer -- no intermediate heap allocation the way fmt.aprintf would need.
//
// FORMATS INTO ONE BYTE MORE THAN IT KEEPS, and that is the whole truncation
// detector. fmt.bprintf simply stops when its backing array is full and has no
// way to report that it wanted more, so "did it fit?" cannot be asked of a
// CAP-sized buffer -- a result of exactly CAP is indistinguishable between an
// exact fit and a clip. With CAP+1 bytes to write into, a result longer than
// CAP is proof the real output did not fit, and a result of CAP or less is
// proof it did. Exact in both directions, at the cost of one stack byte.
msg_text_fmt :: proc(format: string, args: ..any) -> Msg_Text {
	scratch: [MSG_TEXT_CAP + 1]u8
	s := fmt.bprintf(scratch[:], format, ..args)

	m: Msg_Text
	n := copy(m.buf[:], s)
	m.len = u8(n)
	m.truncated = len(s) > MSG_TEXT_CAP
	return m
}

// Whether this Msg_Text is the WHOLE text it was built from, or a 255-byte
// prefix of it.
//
// An accessor rather than a bare field read so that the question has one
// spelling everywhere and this doc comment has somewhere to live. A caller that
// wants the full text of an arbitrarily long payload wants a different carrier
// -- Msg_Text cannot be one and stay POD -- but a caller that merely wants to
// say "(truncated)" in its status line can, now, know.
@(require_results)
msg_text_truncated :: proc(m: Msg_Text) -> bool {
	return m.truncated
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
