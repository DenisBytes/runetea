package runetea

import "core:testing"

@(test)
test_decode_printable_runes :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("abc"), &out)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, out[0].r, 'a')
	testing.expect_value(t, out[2].r, 'c')
	testing.expect_value(t, out[0].code, Key_Code.Rune)
}

@(test)
test_decode_ctrl_c :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys([]u8{0x03}, &out)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].r, 'c')
	testing.expect(t, .Ctrl in out[0].mods, "ctrl modifier must be set")
}

@(test)
test_decode_arrow_keys :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e[A\e[B\e[C\e[D"), &out)
	testing.expect_value(t, n, 12)
	testing.expect_value(t, len(out), 4)
	testing.expect_value(t, out[0].code, Key_Code.Up)
	testing.expect_value(t, out[1].code, Key_Code.Down)
	testing.expect_value(t, out[2].code, Key_Code.Right)
	testing.expect_value(t, out[3].code, Key_Code.Left)
}

@(test)
test_decode_enter_and_escape :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	decode_keys([]u8{'\r'}, &out)
	testing.expect_value(t, out[0].code, Key_Code.Enter)

	clear(&out)
	decode_keys([]u8{0x1b}, &out)
	testing.expect_value(t, out[0].code, Key_Code.Escape)
}

// A partial escape sequence must be held back, not misdecoded as a lone Escape.
// This is the classic bug: a CSI split across two reads becomes ESC + garbage.
@(test)
test_partial_sequence_is_held_back :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e["), &out)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(out), 0)
}

// A user double-tapping Escape (common in modal/vim-like UIs) must read as
// two Escape keypresses, not collapse into a single spurious Alt+<ESC-rune>.
@(test)
test_decode_double_escape :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys([]u8{0x1b, 0x1b}, &out)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0].code, Key_Code.Escape)
	testing.expect_value(t, out[1].code, Key_Code.Escape)
}

// A parameterised CSI this decoder assigns no meaning to must consume the
// whole sequence and emit nothing -- not leak its trailing bytes as spurious
// rune keypresses.
//
// The sequences chosen here are deliberately ones that are OUT of T1-H's
// scope rather than merely unimplemented: bracketed paste start/end, a Kitty
// keyboard flags report, an SGR mouse report, and F13 (CSI 25~, beyond the
// F1-F12 vocabulary Key_Code carries). This test used to use "\e[5~", which
// was a fine example of "unsupported" when the decoder had no tilde table at
// all; PageUp is decoded now, so keeping it would have made the test assert
// the opposite of the feature.
@(test)
test_decode_unsupported_csi_is_cleanly_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{"\e[200~", "\e[201~", "\e[?1u", "\e[<0;10;5M", "\e[25~", "\e[9~"}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0", seq, len(out))
	}
}

// The same contract on the SS3 path: keypad keys (DECKPAM) are out of T1-H's
// scope, and an SS3 sequence for one must be swallowed whole rather than
// leaking its GL byte as a rune.
@(test)
test_decode_unsupported_ss3_is_cleanly_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{"\eOM", "\eOX", "\eOp", "\eOE"}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0", seq, len(out))
	}
}

// The first 3 bytes of Ctrl+Right (ESC [ 1 ; 5 C) arriving alone, as if a
// read split mid-sequence: the final byte hasn't arrived, so this must hold
// back completely, not discard "\e[1" and let ";5C" decode as three garbage
// runes once the rest lands.
@(test)
test_decode_partial_parameterised_csi_is_held_back :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e[1"), &out)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(out), 0)

	// Once the rest of the sequence arrives, it resolves as ONE key -- not
	// three garbage runes ';', '5', 'C'. Before T1-H this asserted zero keys
	// (the sequence was consumed and ignored); the byte-level contract under
	// test -- "hold back, then resolve as a single unit" -- is unchanged, only
	// the unit's meaning is now known.
	n = decode_keys(transmute([]u8)string("\e[1;5C"), &out)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Right, mods = {.Ctrl}})
}

// 'é' (U+00E9) encodes as the two bytes 0xC3 0xA9. Only the lead byte
// arriving must hold back rather than decode to a U+FFFD replacement rune;
// this is the same "split across a read boundary" bug as the partial CSI
// tests above, but on the plain-printable-rune path.
@(test)
test_decode_split_utf8_rune_is_held_back :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys([]u8{0xC3}, &out)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(out), 0)

	n = decode_keys([]u8{0xC3, 0xA9}, &out)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].code, Key_Code.Rune)
	testing.expect_value(t, out[0].r, rune(0x00E9))
}

// ---------------------------------------------------------------------------
// T1-H: the real CSI/SS3 decoder.
//
// One shared table drives two tests that check different properties of the
// same byte strings:
//   - test_decode_key_table feeds each sequence whole and checks the decoded
//     Key_Msg AND the consumed count;
//   - test_split_at_every_byte_boundary feeds every proper prefix of each
//     sequence and checks the HOLD-BACK CONTRACT (input.odin).
// Keeping them on one table is what makes the second test non-vacuous: a
// sequence cannot be added to the decoder's vocabulary without automatically
// being subjected to the split test too.
// ---------------------------------------------------------------------------

@(private = "file")
Key_Case :: struct {
	seq:   string,
	want:  [2]Key_Msg,
	nwant: int,
}

@(private = "file")
key_cases := [?]Key_Case{
	// -- CSI tilde: navigation ------------------------------------------
	{"\e[1~", {{code = .Home},      {}}, 1},
	{"\e[2~", {{code = .Insert},    {}}, 1},
	{"\e[3~", {{code = .Delete},    {}}, 1},
	{"\e[4~", {{code = .End},       {}}, 1},
	{"\e[5~", {{code = .Page_Up},   {}}, 1},
	{"\e[6~", {{code = .Page_Down}, {}}, 1},
	{"\e[7~", {{code = .Home},      {}}, 1},
	{"\e[8~", {{code = .End},       {}}, 1},

	// -- CSI letter finals ----------------------------------------------
	{"\e[A", {{code = .Up},    {}}, 1},
	{"\e[B", {{code = .Down},  {}}, 1},
	{"\e[C", {{code = .Right}, {}}, 1},
	{"\e[D", {{code = .Left},  {}}, 1},
	{"\e[H", {{code = .Home},  {}}, 1},
	{"\e[F", {{code = .End},   {}}, 1},

	// -- F1-F12, all three encodings ------------------------------------
	// SS3 (what xterm actually sends for F1-F4).
	{"\eOP", {{code = .F1}, {}}, 1},
	{"\eOQ", {{code = .F2}, {}}, 1},
	{"\eOR", {{code = .F3}, {}}, 1},
	{"\eOS", {{code = .F4}, {}}, 1},
	// CSI legacy, bare and with the redundant "1" parameter some terminals
	// emit (linux console, a few terminfo entries).
	{"\e[P",  {{code = .F1}, {}}, 1},
	{"\e[Q",  {{code = .F2}, {}}, 1},
	{"\e[R",  {{code = .F3}, {}}, 1},
	{"\e[S",  {{code = .F4}, {}}, 1},
	{"\e[1P", {{code = .F1}, {}}, 1},
	{"\e[1Q", {{code = .F2}, {}}, 1},
	{"\e[1S", {{code = .F4}, {}}, 1},
	// CSI tilde. 11-14 duplicate F1-F4 on terminals that do not use SS3.
	{"\e[11~", {{code = .F1},  {}}, 1},
	{"\e[12~", {{code = .F2},  {}}, 1},
	{"\e[13~", {{code = .F3},  {}}, 1},
	{"\e[14~", {{code = .F4},  {}}, 1},
	{"\e[15~", {{code = .F5},  {}}, 1},
	{"\e[17~", {{code = .F6},  {}}, 1},
	{"\e[18~", {{code = .F7},  {}}, 1},
	{"\e[19~", {{code = .F8},  {}}, 1},
	{"\e[20~", {{code = .F9},  {}}, 1},
	{"\e[21~", {{code = .F10}, {}}, 1},
	{"\e[23~", {{code = .F11}, {}}, 1},
	{"\e[24~", {{code = .F12}, {}}, 1},

	// -- SS3 arrows (DECCKM application cursor key mode) -----------------
	{"\eOA", {{code = .Up},    {}}, 1},
	{"\eOB", {{code = .Down},  {}}, 1},
	{"\eOC", {{code = .Right}, {}}, 1},
	{"\eOD", {{code = .Left},  {}}, 1},
	{"\eOH", {{code = .Home},  {}}, 1},
	{"\eOF", {{code = .End},   {}}, 1},

	// -- xterm modifier parameters: 1 + bitmask -------------------------
	{"\e[1;5A", {{code = .Up,     mods = {.Ctrl}},          {}}, 1},
	{"\e[1;2C", {{code = .Right,  mods = {.Shift}},         {}}, 1},
	{"\e[3;5~", {{code = .Delete, mods = {.Ctrl}},          {}}, 1},
	{"\e[1;3H", {{code = .Home,   mods = {.Alt}},           {}}, 1},
	{"\e[1;2D", {{code = .Left,   mods = {.Shift}},         {}}, 1},
	{"\e[1;7C", {{code = .Right,  mods = {.Ctrl, .Alt}},    {}}, 1},
	{"\e[1;8B", {{code = .Down,   mods = {.Ctrl, .Alt, .Shift}}, {}}, 1},
	{"\e[1;9A", {{code = .Up,     mods = {.Meta}},          {}}, 1},
	{"\e[1;10D",{{code = .Left,   mods = {.Meta, .Shift}},  {}}, 1},
	{"\e[5;5~", {{code = .Page_Up, mods = {.Ctrl}},         {}}, 1},
	{"\e[15;2~",{{code = .F5,     mods = {.Shift}},         {}}, 1},
	{"\e[1;5P", {{code = .F1,     mods = {.Ctrl}},          {}}, 1},
	{"\e[1;2R", {{code = .F3,     mods = {.Shift}},         {}}, 1},
	{"\e[1;5F", {{code = .End,    mods = {.Ctrl}},          {}}, 1},
	// SS3 with a leading modifier parameter (rare, but xterm emits it for
	// modified F1-F4 in some configurations).
	{"\eO5A", {{code = .Up, mods = {.Ctrl}}, {}}, 1},
	{"\eO2P", {{code = .F1, mods = {.Shift}}, {}}, 1},

	// -- T1-J: Kitty keyboard protocol, CSI <code> [;<mods>[:<ev>]] u ---
	//
	// These live in THIS table on purpose: it is what subjects them to
	// test_split_at_every_byte_boundary, and a Kitty sequence is longer than
	// anything else here (up to 12 bytes), so it is the best hold-back
	// exercise in the file.
	//
	// THE WHOLE POINT of the protocol is the pairs below: each legacy
	// collision becomes two distinct byte sequences.
	{"\e[9u",     {{code = .Tab},   {}}, 1},   // Tab
	{"\e[105;5u", {{code = .Rune, r = 'i', mods = {.Ctrl}}, {}}, 1},   // ...vs Ctrl+i
	{"\e[13u",    {{code = .Enter}, {}}, 1},   // Enter
	{"\e[109;5u", {{code = .Rune, r = 'm', mods = {.Ctrl}}, {}}, 1},   // ...vs Ctrl+m
	{"\e[27u",    {{code = .Escape},{}}, 1},   // Escape
	{"\e[91;5u",  {{code = .Rune, r = '[', mods = {.Ctrl}}, {}}, 1},   // ...vs Ctrl+[
	{"\e[8u",     {{code = .Backspace}, {}}, 1},
	{"\e[104;5u", {{code = .Rune, r = 'h', mods = {.Ctrl}}, {}}, 1},   // ...vs Ctrl+h
	{"\e[127u",   {{code = .Backspace}, {}}, 1},

	// Plain and modified text keys.
	{"\e[97u",    {{code = .Rune, r = 'a'}, {}}, 1},
	{"\e[97;5u",  {{code = .Rune, r = 'a', mods = {.Ctrl}}, {}}, 1},
	{"\e[97;3u",  {{code = .Rune, r = 'a', mods = {.Alt}}, {}}, 1},
	{"\e[97;7u",  {{code = .Rune, r = 'a', mods = {.Ctrl, .Alt}}, {}}, 1},
	{"\e[97;8u",  {{code = .Rune, r = 'a', mods = {.Ctrl, .Alt, .Shift}}, {}}, 1},
	{"\e[32u",    {{code = .Space, r = ' '}, {}}, 1},
	{"\e[0u",     {{code = .Space, mods = {.Ctrl}}, {}}, 1},   // Ctrl+Space, no text

	// THE KITTY BITMASK IS NOT THE XTERM BITMASK. Bit 8 is Super in Kitty
	// (Meta in xterm) and bit 32 is Meta in Kitty (nothing in xterm). Decode
	// these with xterm_mods and both lines below flip: ;9u would gain .Meta
	// and ;33u would lose it. That is the non-vacuity lever for kitty_mods.
	{"\e[97;9u",  {{code = .Rune, r = 'a'}, {}}, 1},            // Super: no member, dropped
	{"\e[97;33u", {{code = .Rune, r = 'a', mods = {.Meta}}, {}}, 1},
	{"\e[97;65u", {{code = .Rune, r = 'a'}, {}}, 1},            // CapsLock: dropped
	{"\e[97;129u",{{code = .Rune, r = 'a'}, {}}, 1},            // NumLock: dropped

	// Event types (the ':' sub-parameter on the modifier field).
	{"\e[97;1:1u", {{kind = .Press,   code = .Rune, r = 'a'}, {}}, 1},
	{"\e[97;1:2u", {{kind = .Repeat,  code = .Rune, r = 'a'}, {}}, 1},
	{"\e[97;1:3u", {{kind = .Release, code = .Rune, r = 'a'}, {}}, 1},
	{"\e[97;5:3u", {{kind = .Release, code = .Rune, r = 'a', mods = {.Ctrl}}, {}}, 1},
	{"\e[57352;5:2u", {{kind = .Repeat, code = .Up, mods = {.Ctrl}}, {}}, 1},

	// Functional keycodes: the 57344+ private-use block.
	{"\e[57344u", {{code = .Escape},    {}}, 1},
	{"\e[57345u", {{code = .Enter},     {}}, 1},
	{"\e[57346u", {{code = .Tab},       {}}, 1},
	{"\e[57347u", {{code = .Backspace}, {}}, 1},
	{"\e[57348u", {{code = .Insert},    {}}, 1},
	{"\e[57349u", {{code = .Delete},    {}}, 1},
	{"\e[57350u", {{code = .Left},      {}}, 1},
	{"\e[57351u", {{code = .Right},     {}}, 1},
	{"\e[57352u", {{code = .Up},        {}}, 1},
	{"\e[57353u", {{code = .Down},      {}}, 1},
	{"\e[57354u", {{code = .Page_Up},   {}}, 1},
	{"\e[57355u", {{code = .Page_Down}, {}}, 1},
	{"\e[57356u", {{code = .Home},      {}}, 1},
	{"\e[57357u", {{code = .End},       {}}, 1},
	{"\e[57364u", {{code = .F1},        {}}, 1},
	{"\e[57375u", {{code = .F12},       {}}, 1},
	{"\e[57352;5u", {{code = .Up, mods = {.Ctrl}}, {}}, 1},

	// Alternate key reporting: <key>:<shifted>:<base-layout>. The shifted
	// codepoint is what the keypress actually produces, so it wins for `r`;
	// the base-layout codepoint has nowhere to go and is dropped.
	{"\e[97:65;2u",    {{code = .Rune, r = 'A', mods = {.Shift}}, {}}, 1},
	{"\e[97:65:97;2u", {{code = .Rune, r = 'A', mods = {.Shift}}, {}}, 1},
	{"\e[97::97u",     {{code = .Rune, r = 'a'}, {}}, 1},   // empty shifted sub-param

	// Text-as-codepoints, the third field. One codepoint populates `r`.
	{"\e[97;;98u",   {{code = .Rune, r = 'b'}, {}}, 1},
	{"\e[97;1:1;98u",{{code = .Rune, r = 'b'}, {}}, 1},
	// ...several do not: Key_Msg.r is ONE rune and there is nowhere to put the
	// rest, so the text field is ignored wholesale and `r` falls back to the
	// key code. Documented in kitty_decode; deliberately not a silent truncation.
	{"\e[97;;98:99u", {{code = .Rune, r = 'a'}, {}}, 1},

	// -- two sequences back to back -------------------------------------
	{"\e[A\e[1;5D", {{code = .Up}, {code = .Left, mods = {.Ctrl}}}, 2},
	{"\eOA\e[5~",   {{code = .Up}, {code = .Page_Up}}, 2},
	// Kitty and legacy bytes in ONE buffer must both decode (T1-J req. 7).
	{"\e[97;5u\e[A", {{code = .Rune, r = 'a', mods = {.Ctrl}}, {code = .Up}}, 2},
	{"\e[A\e[97u",   {{code = .Up}, {code = .Rune, r = 'a'}}, 2},
}

@(test)
test_decode_key_table :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for c in key_cases {
		clear(&out)
		n := decode_keys(transmute([]u8)c.seq, &out)
		testing.expectf(t, n == len(c.seq), "%q: consumed %d, want %d", c.seq, n, len(c.seq))
		if !testing.expectf(t, len(out) == c.nwant,
			"%q: emitted %d keys, want %d (%v)", c.seq, len(out), c.nwant, out[:]) {
			continue
		}
		for k in 0 ..< c.nwant {
			testing.expectf(t, out[k] == c.want[k],
				"%q: key %d = %v, want %v", c.seq, k, out[k], c.want[k])
		}
	}
}

// THE test for the HOLD-BACK CONTRACT (input.odin). Every sequence in the
// table is fed as each of its proper prefixes, and the decoder must hold back
// completely -- consume nothing, emit nothing -- so the reader loop retries
// the whole thing when the rest lands.
//
// There are exactly two exceptions, and both are the SAME documented T1
// ambiguity (no timer to tell "sequence in flight" from "key pressed"):
//   - a lone ESC at the end of the buffer resolves as Escape;
//   - "\eO" at the end of the buffer resolves as Alt+O.
// Asserting those two positively, rather than exempting them, is what stops
// this test from quietly degenerating into "anything goes at the boundary".
//
// Only the single-sequence table entries are split here: a prefix of a
// two-sequence entry legitimately decodes its first sequence, which is a
// different property (and the one test_complete_then_partial checks).
// `checked` guards against the filter silently eating the whole table.
@(test)
test_split_at_every_byte_boundary :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	checked := 0
	for c in key_cases {
		if c.nwant != 1 { continue }
		b := transmute([]u8)c.seq
		for k in 1 ..< len(b) {
			checked += 1
			clear(&out)
			n := decode_keys(b[:k], &out)
			switch {
			case k == 1:
				// Lone ESC: the documented ambiguity, resolved as Escape.
				testing.expectf(t, n == 1 && len(out) == 1 && out[0] == Key_Msg{code = .Escape},
					"%q[:1]: got n=%d %v, want Escape", c.seq, n, out[:])
			case k == 2 && b[1] == 'O':
				// "\eO" with no third byte: the SAME ambiguity, resolved as
				// Alt+O rather than held back. See input.odin.
				testing.expectf(t, n == 2 && len(out) == 1 &&
					out[0] == Key_Msg{code = .Rune, r = 'O', mods = {.Alt}},
					"%q[:2]: got n=%d %v, want Alt+O", c.seq, n, out[:])
			case:
				testing.expectf(t, n == 0 && len(out) == 0,
					"%q[:%d]: got n=%d %v, want a complete hold-back",
					c.seq, k, n, out[:])
			}
		}
	}
	// Floor raised from 100 to 500 when T1-J added the Kitty block (531 split
	// points at the time of writing, up from 186). The floor exists so deleting
	// a chunk of the table cannot quietly make this test vacuous, so it has to
	// track the table's actual size.
	testing.expectf(t, checked >= 500, "only %d split points exercised -- table shrank?", checked)
}

// A complete sequence followed by a partial one: the complete prefix must be
// decoded and the partial tail held back, so `consumed` lands exactly on the
// boundary between them.
@(test)
test_complete_then_partial :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e[5~\e[1;5"), &out)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].code, Key_Code.Page_Up)

	clear(&out)
	n = decode_keys(transmute([]u8)string("\eOA\eO5"), &out)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].code, Key_Code.Up)
}

// The ESC O ambiguity, in both directions. This is the one place where the
// decoder's answer depends on whether a byte has arrived yet, so both answers
// need pinning down.
@(test)
test_esc_o_ambiguity :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)

	// No third byte: Alt+O (a real keypress), consumed.
	n := decode_keys(transmute([]u8)string("\eO"), &out)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].code, Key_Code.Rune)
	testing.expect_value(t, out[0].r, 'O')
	testing.expect(t, .Alt in out[0].mods, "alt modifier must be set")

	// A third byte present: SS3, never Alt+O followed by a stray rune.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\eOA"), &out)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].code, Key_Code.Up)

	// The asymmetry with "\e[": CSI is never a key on its own, so it holds
	// back where "\eO" resolves.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\e["), &out)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(out), 0)

	// Alt+O really is reachable when it is not the last thing in the buffer:
	// "\eOx" is SS3 with an unrecognised GL byte, so it is swallowed whole --
	// the documented cost of resolving the ambiguity without a timer.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\eOz"), &out)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(out), 0)
}

// decode_c0 is the single place the C0 normalisation policy lives. These
// assertions pin the DEFAULT policy -- the `{}` flag set, which by construction
// equals ultraviolet's defaults (see Legacy_Key). Named keys win and carry no
// Ctrl flag, so Ctrl+I is indistinguishable from Tab and Ctrl+M from Enter.
// Choosing the other side of any of these collisions is what Legacy_Key_Encoding
// is for; test_legacy_key_encoding_flags below is where the opt-outs are pinned.
@(test)
test_c0_policy :: proc(t: ^testing.T) {
	testing.expect_value(t, decode_c0('\r', {}), Key_Msg{code = .Enter})
	testing.expect_value(t, decode_c0(0x0d, {}), Key_Msg{code = .Enter})   // ctrl+m == enter
	// LF is Ctrl+J, NOT a second spelling of Enter: term.odin clears ICRNL, so
	// a real Enter arrives as 0x0D and a 0x0A that shows up genuinely is Ctrl+J.
	// This used to report Enter, which silently stole Ctrl+J from every app.
	testing.expect_value(t, decode_c0('\n', {}), Key_Msg{code = .Rune, r = 'j', mods = {.Ctrl}})
	// NUL is Ctrl+Space (r left empty: Ctrl+Space produces no text). This used
	// to fall through the b+0x60 arithmetic onto '`', which is neither '@'
	// (0x40) nor ' ' (0x20) -- just a wrong rune.
	testing.expect_value(t, decode_c0(0x00, {}), Key_Msg{code = .Space, mods = {.Ctrl}})
	testing.expect_value(t, decode_c0('\t', {}), Key_Msg{code = .Tab})
	testing.expect_value(t, decode_c0(0x09, {}), Key_Msg{code = .Tab})     // ctrl+i == tab
	testing.expect_value(t, decode_c0(0x1b, {}), Key_Msg{code = .Escape})  // ctrl+[ == escape
	testing.expect_value(t, decode_c0(' ',  {}), Key_Msg{code = .Space, r = ' '})
	testing.expect_value(t, decode_c0(0x7f, {}), Key_Msg{code = .Backspace})
	// 0x08 is Ctrl+h, NOT Backspace, unless .Backspace says otherwise.
	testing.expect_value(t, decode_c0(0x08, {}), Key_Msg{code = .Rune, r = 'h', mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(0x03, {}), Key_Msg{code = .Rune, r = 'c', mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(0x1a, {}), Key_Msg{code = .Rune, r = 'z', mods = {.Ctrl}})
	// FS..US take the 0x40 offset, not the 0x60 letter offset -- they are
	// Ctrl+punctuation, not Ctrl+letter. The letter offset used to land these
	// on '|' '}' '~' and DEL, none of which the user pressed. Ctrl+\ is the
	// one that bites: it is a real, commonly-bound key.
	testing.expect_value(t, decode_c0(0x1c, {}), Key_Msg{code = .Rune, r = '\\', mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(0x1d, {}), Key_Msg{code = .Rune, r = ']',  mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(0x1e, {}), Key_Msg{code = .Rune, r = '^',  mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(0x1f, {}), Key_Msg{code = .Rune, r = '_',  mods = {.Ctrl}})
	// The boundary either side of the 0x1B hole: 0x1A keeps the letter offset
	// (asserted above as 'z'), 0x1C switches to the punctuation offset. An
	// off-by-one in the range check would break exactly one of these two.
	testing.expect_value(t, decode_c0(0x1b, {}), Key_Msg{code = .Escape})
}

// ---------------------------------------------------------------------------
// T1-I: Legacy_Key_Encoding.
// ---------------------------------------------------------------------------

// Every flag, both ways, through the FULL decoder (not just decode_c0) so the
// plumbing is covered too, and with `consumed` asserted so a flag cannot
// accidentally change how many bytes a sequence eats.
//
// The `clear` column doubles as the proof that the zero value is the sane
// default: it is the same table that would be written for a decoder with no
// flags at all.
@(test)
test_legacy_key_encoding_flags :: proc(t: ^testing.T) {
	Case :: struct {
		name:      string,
		flag:      Legacy_Key,
		seq:       string,
		off, on:   Key_Msg,
	}
	cases := [?]Case{
		{"ctrl+at",    .Ctrl_At,            "\x00",
			{code = .Space, mods = {.Ctrl}},  {code = .Rune, r = '@', mods = {.Ctrl}}},
		{"ctrl+i",     .Ctrl_I,             "\t",
			{code = .Tab},                    {code = .Rune, r = 'i', mods = {.Ctrl}}},
		{"ctrl+m",     .Ctrl_M,             "\r",
			{code = .Enter},                  {code = .Rune, r = 'm', mods = {.Ctrl}}},
		{"ctrl+[",     .Ctrl_Open_Bracket,  "\e",
			{code = .Escape},                 {code = .Rune, r = '[', mods = {.Ctrl}}},
		// One flag, two bytes: with it set the Backspace KEY is 0x08, which
		// frees 0x7F to be Delete. See decode_c0 for why this deviates from
		// ultraviolet, which leaves 0x08 as ctrl+h even with the flag on.
		{"backspace/BS",  .Backspace, "\x08",
			{code = .Rune, r = 'h', mods = {.Ctrl}}, {code = .Backspace}},
		{"backspace/DEL", .Backspace, "\x7f",
			{code = .Backspace},              {code = .Delete}},
		{"find",       .Find,   "\e[1~",
			{code = .Home},                   {code = .Find}},
		{"select",     .Select, "\e[4~",
			{code = .End},                    {code = .Select}},
		// The flags reach the modified forms too, not just the bare ones.
		{"find+ctrl",  .Find,   "\e[1;5~",
			{code = .Home, mods = {.Ctrl}},   {code = .Find, mods = {.Ctrl}}},
		{"select+alt", .Select, "\e[4;3~",
			{code = .End, mods = {.Alt}},     {code = .Select, mods = {.Alt}}},
	}

	out := make([dynamic]Key_Msg); defer delete(out)
	for c in cases {
		for on in ([?]bool{false, true}) {
			legacy: Legacy_Key_Encoding
			if on { legacy = {c.flag} }
			want := c.on if on else c.off

			clear(&out)
			n := decode_keys(transmute([]u8)c.seq, &out, legacy)
			testing.expectf(t, n == len(c.seq), "%s (set=%v): consumed %d, want %d",
				c.name, on, n, len(c.seq))
			if !testing.expectf(t, len(out) == 1, "%s (set=%v): emitted %d keys, want 1",
				c.name, on, len(out)) { continue }
			testing.expectf(t, out[0] == want, "%s (set=%v): got %v, want %v",
				c.name, on, out[0], want)
		}
	}

	// A flag must move ONLY its own byte. Turn every flag on at once and check
	// that the bytes nobody claimed are untouched -- this is what would catch a
	// stray fallthrough between the switch arms.
	all := Legacy_Key_Encoding{.Ctrl_At, .Ctrl_I, .Ctrl_M, .Ctrl_Open_Bracket,
	                           .Backspace, .Find, .Select}
	testing.expect_value(t, decode_c0(0x03, all), Key_Msg{code = .Rune, r = 'c', mods = {.Ctrl}})
	testing.expect_value(t, decode_c0('\n', all), Key_Msg{code = .Rune, r = 'j', mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(' ',  all), Key_Msg{code = .Space, r = ' '})

	clear(&out)
	n := decode_keys(transmute([]u8)string("\e[2~\e[3~\e[7~\e[8~"), &out, all)
	testing.expect_value(t, n, 16)
	testing.expect_value(t, len(out), 4)
	testing.expect_value(t, out[0], Key_Msg{code = .Insert})
	testing.expect_value(t, out[1], Key_Msg{code = .Delete})
	// 7~/8~ are rxvt's Home/End and are NOT the Find/Select keys: ultraviolet
	// leaves them unconditional, and so do we.
	testing.expect_value(t, out[2], Key_Msg{code = .Home})
	testing.expect_value(t, out[3], Key_Msg{code = .End})
}

// THE TRAP. Ctrl_Open_Bracket must rename a RESOLVED Escape and nothing else.
// ESC is intercepted above the C0 gate because it introduces sequences, so a
// naive implementation that returns ctrl+[ the moment it sees 0x1b destroys
// every arrow key, every function key, and Alt+<anything> at once -- and each
// of those failures looks like an unrelated bug at the call site.
//
// Every assertion below is run with the flag SET. Only the two lone-Escape
// resolutions may change shape.
@(test)
test_ctrl_open_bracket_leaves_sequences_alone :: proc(t: ^testing.T) {
	L := Legacy_Key_Encoding{.Ctrl_Open_Bracket}
	ctrl_bracket := Key_Msg{code = .Rune, r = '[', mods = {.Ctrl}}
	out := make([dynamic]Key_Msg); defer delete(out)

	// Sequences: byte-identical results to the flag-clear decoder.
	Seq :: struct { seq: string, want: Key_Msg }
	for c in ([?]Seq{
		{"\e[A",     {code = .Up}},
		{"\eOP",     {code = .F1}},
		{"\e[1;5A",  {code = .Up, mods = {.Ctrl}}},
		{"\e[3~",    {code = .Delete}},
		{"\eOA",     {code = .Up}},
		{"\ea",      {code = .Rune, r = 'a', mods = {.Alt}}},   // Alt+a, not ctrl+[ then 'a'
		{"\e[",      {}},                                       // held back, emits nothing
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)c.seq, &out, L)
		nwant := len(c.seq)
		kwant := 1
		if c.seq == "\e[" { nwant, kwant = 0, 0 }   // the hold-back case
		testing.expectf(t, n == nwant, "%q: consumed %d, want %d", c.seq, n, nwant)
		if !testing.expectf(t, len(out) == kwant, "%q: emitted %d keys, want %d (%v)",
			c.seq, len(out), kwant, out[:]) { continue }
		if kwant == 1 {
			testing.expectf(t, out[0] == c.want, "%q: got %v, want %v", c.seq, out[0], c.want)
		}
	}

	// The two places an Escape is actually RESOLVED -- these, and only these,
	// change shape.
	clear(&out)
	n := decode_keys([]u8{0x1b}, &out, L)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], ctrl_bracket)

	clear(&out)
	n = decode_keys([]u8{0x1b, 0x1b}, &out, L)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0], ctrl_bracket)
	testing.expect_value(t, out[1], ctrl_bracket)

	// A complete sequence followed by a lone trailing ESC: the sequence must
	// still decode normally, and only the tail becomes ctrl+[.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\e[A\e"), &out, L)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})
	testing.expect_value(t, out[1], ctrl_bracket)

	// And the hold-back contract itself is untouched: every proper prefix of a
	// real sequence still holds back completely, with the flag set. This is the
	// same property test_split_at_every_byte_boundary runs with the flag clear.
	for seq in ([?]string{"\e[1;5A", "\e[15~", "\eO2P"}) {
		b := transmute([]u8)seq
		for k in 2 ..< len(b) {
			// "\eO" alone is the documented Alt+O resolution, not a hold-back
			// (see decode_keys' doc comment); the flag does not touch it either.
			if k == 2 && b[1] == 'O' { continue }
			clear(&out)
			n = decode_keys(b[:k], &out, L)
			testing.expectf(t, n == 0 && len(out) == 0,
				"%q[:%d]: got n=%d %v, want a complete hold-back", seq, k, n, out[:])
		}
	}
}

// ---------------------------------------------------------------------------
// T1-J: Kitty keyboard protocol.
// ---------------------------------------------------------------------------

// THE DISPATCH TRAP. 'u' is now a key final byte, but four other `CSI ... u`
// forms share it and none of them is a keypress:
//   CSI ? <flags> u   the Kitty flags-query REPLY
//   CSI = <flags> ; <mode> u   set flags
//   CSI > <flags> u   push flags
//   CSI < <n> u       pop flags
// All four carry a private prefix byte (0x3C-0x3F) where a digit belongs, and
// all four must stay cleanly ignored -- consumed whole, nothing emitted --
// exactly as they were before 'u' meant anything. A decoder that reads the
// prefix byte as part of a parameter would report the flags word as a keypress.
@(test)
test_kitty_non_key_csi_u_forms_are_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{
		"\e[?1u", "\e[?0u", "\e[?31u",     // flags reply
		"\e[=1u", "\e[=5;1u", "\e[=0;3u",  // set flags
		"\e[>1u", "\e[>0u",                // push flags
		"\e[<1u", "\e[<u",                 // pop flags
		"\e[u",                            // no parameters at all
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)",
			seq, len(out), out[:])
	}
}

// Requirement 4: functional keys with no Key_Code member follow the decoder's
// established policy -- consume the whole sequence, emit nothing. Never leak
// the digits as garbage runes, and never fold them onto some nearby key.
@(test)
test_kitty_unmapped_functional_keys_are_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{
		"\e[57358u",    // CapsLock
		"\e[57359u",    // ScrollLock
		"\e[57360u",    // NumLock
		"\e[57361u",    // PrintScreen
		"\e[57362u",    // Pause
		"\e[57363u",    // Menu
		"\e[57376u",    // F13
		"\e[57398u",    // F35
		"\e[57399u",    // Keypad 0
		"\e[57427u",    // Keypad Begin
		"\e[57428u",    // MediaPlay
		"\e[57441u",    // LeftShift (a lone modifier keypress)
		"\e[57452u",    // RightMeta
		"\e[57454u",    // IsoLevel5Shift
		"\e[57441;1:3u",// LeftShift release -- still nothing
		"\e[63743u",    // top of the BMP private-use area, unassigned by Kitty
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)",
			seq, len(out), out[:])
	}
}

// Press is the ZERO VALUE of Key_Kind and must stay that way: every legacy
// path builds a Key_Msg without naming `kind`, so a reordered enum would
// silently relabel every keypress in the decoder as a release.
@(test)
test_key_kind_press_is_the_zero_value :: proc(t: ^testing.T) {
	testing.expect_value(t, Key_Kind{}, Key_Kind.Press)
	testing.expect_value(t, Key_Msg{}.kind, Key_Kind.Press)

	out := make([dynamic]Key_Msg); defer delete(out)
	decode_keys(transmute([]u8)string("a\e[A\r"), &out)
	testing.expect_value(t, len(out), 3)
	for k in out { testing.expect_value(t, k.kind, Key_Kind.Press) }
}

// Legacy_Key_Encoding must NOT reach the Kitty path. The flags exist to
// arbitrate a collision the legacy byte encoding forces; Kitty removes the
// collision outright (Tab is 9, Ctrl+i is 105 with the Ctrl bit), so honouring
// them here would re-introduce the ambiguity the protocol just eliminated --
// and would make Ctrl+i and Tab indistinguishable again for no reason.
@(test)
test_kitty_ignores_legacy_flags :: proc(t: ^testing.T) {
	all := Legacy_Key_Encoding{.Ctrl_At, .Ctrl_I, .Ctrl_M, .Ctrl_Open_Bracket,
	                           .Backspace, .Find, .Select}
	out := make([dynamic]Key_Msg); defer delete(out)
	Case :: struct { seq: string, want: Key_Msg }
	for c in ([?]Case{
		{"\e[9u",   {code = .Tab}},
		{"\e[13u",  {code = .Enter}},
		{"\e[27u",  {code = .Escape}},
		{"\e[0u",   {code = .Space, mods = {.Ctrl}}},
		{"\e[8u",   {code = .Backspace}},
		{"\e[127u", {code = .Backspace}},
	}) {
		for legacy in ([?]Legacy_Key_Encoding{{}, all}) {
			clear(&out)
			n := decode_keys(transmute([]u8)c.seq, &out, legacy)
			testing.expectf(t, n == len(c.seq), "%q (%v): consumed %d, want %d",
				c.seq, legacy, n, len(c.seq))
			if !testing.expectf(t, len(out) == 1, "%q (%v): emitted %d keys, want 1",
				c.seq, legacy, len(out)) { continue }
			testing.expectf(t, out[0] == c.want, "%q (%v): got %v, want %v",
				c.seq, legacy, out[0], c.want)
		}
	}
}

// Sub-parameter acceptance is SCOPED TO THE 'u' FINAL, deliberately. Every
// other final byte still rejects ':' outright, which is what keeps SGR mouse
// reports, DECRPM replies and the Kitty legacy-key extension on the
// cleanly-ignored path rather than in some half-parsed state. Pinning it here
// so widening csi_params later is a conscious act with a failing test attached.
@(test)
test_subparams_are_rejected_outside_csi_u :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{
		"\e[1;5:3A",   // Kitty's event-type extension on a legacy arrow key
		"\e[3;5:3~",   // ...and on a tilde key
		"\e[1:2A",
		"\e[<0;10:5M", // SGR mouse with a stray sub-parameter
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)",
			seq, len(out), out[:])
	}
}

// Kitty parameter edges. Complete sequences, so always fully consumed; the
// question is only whether anything is emitted.
@(test)
test_kitty_parameter_edges :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	Case :: struct { seq: string, nwant: int, want: Key_Msg }
	for c in ([?]Case{
		// mod == 1 is "no modifiers" (the encoding is 1+mask), mod == 0 is not
		// a valid modifier parameter at all.
		{"\e[97;1u", 1, {code = .Rune, r = 'a'}},
		// A PRESENT-BUT-EMPTY key code defaults to 1, per the spec's "CSI
		// number ; modifiers u" default and ultraviolet's Param(1). Key code 1
		// is SOH, which lands in the WezTerm C0-compatibility band as Ctrl+a.
		// Asserted rather than quietly ignored because it is a spec rule this
		// decoder chose to honour, not an accident -- no terminal sends it, and
		// deviating from the reference here would be an undocumented surprise.
		{"\e[;5u",   1, {code = .Rune, r = 'a', mods = {.Ctrl}}},
		{"\e[97;0u", 0, {}},
		{"\e[97;u",  1, {code = .Rune, r = 'a'}},   // empty mods field == default
		{"\e[97;257u", 0, {}},                      // 1+mask tops out at 256
		// An unknown event type is not a reason to drop a real keypress.
		{"\e[97;1:9u", 1, {code = .Rune, r = 'a'}},
		{"\e[97;1:u",  1, {code = .Rune, r = 'a'}},
		// A fourth ';' field is not part of the grammar.
		{"\e[97;1;98;99u", 0, {}},
		// Surrogates and out-of-range codepoints are not scalar values.
		{"\e[55296u", 0, {}},
		{"\e[1114112u", 0, {}},
		// More sub-parameters than Kitty_Params can store. The count still has
		// to be right -- that is what tells a one-codepoint text field from a
		// multi-codepoint one -- even though the values past the third are
		// dropped on the floor.
		{"\e[97;;98:99:100:101u", 1, {code = .Rune, r = 'a'}},
		{"\e[97:65:97:98;2u",     1, {code = .Rune, r = 'A', mods = {.Shift}}},
		// Non-ASCII text keys survive intact.
		{"\e[233u", 1, {code = .Rune, r = 'é'}},
		{"\e[128169u", 1, {code = .Rune, r = '💩'}},
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)c.seq, &out)
		testing.expectf(t, n == len(c.seq), "%q: consumed %d, want %d", c.seq, n, len(c.seq))
		if !testing.expectf(t, len(out) == c.nwant, "%q: emitted %d keys, want %d (%v)",
			c.seq, len(out), c.nwant, out[:]) { continue }
		if c.nwant == 1 {
			testing.expectf(t, out[0] == c.want, "%q: got %v, want %v", c.seq, out[0], c.want)
		}
	}
}

// A modifier parameter out of range must not be forced into a modifier set:
// the sequence is complete, so it is consumed, but nothing is emitted.
// Bits above 8 are masked off rather than mis-reported: this is the LEGACY
// xterm parameter, whose defined bits stop at 8 (Meta), so CSI 1;33A is Up
// with some modifier xterm never named and decodes as plain Up.
//
// (The comment here used to call bit 32 "Kitty's CapsLock". That was wrong on
// both counts -- Kitty's CapsLock is bit 64, its bit 32 is Meta -- and this is
// the legacy parameter anyway, not the Kitty one. See kitty_mods for the real
// Kitty table and test_decode_key_table's "\e[97;33u" for its behaviour.)
@(test)
test_modifier_edges :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)

	// mod == 1 means "no modifiers", not "Shift".
	n := decode_keys(transmute([]u8)string("\e[1;1A"), &out)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})

	// mod == 0 is not a valid xterm modifier param (the encoding is 1+mask).
	clear(&out)
	n = decode_keys(transmute([]u8)string("\e[1;0A"), &out)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 0)

	// A bit xterm never defined, masked off rather than mis-reported.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\e[1;33A"), &out)
	testing.expect_value(t, n, 7)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})

	// A non-1 first parameter on a letter-final CSI is not a key we know.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\e[2;5A"), &out)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 0)
}
