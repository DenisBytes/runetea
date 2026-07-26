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

	// -- two sequences back to back -------------------------------------
	{"\e[A\e[1;5D", {{code = .Up}, {code = .Left, mods = {.Ctrl}}}, 2},
	{"\eOA\e[5~",   {{code = .Up}, {code = .Page_Up}}, 2},
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
	testing.expectf(t, checked >= 100, "only %d split points exercised -- table shrank?", checked)
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
// assertions pin the CURRENT policy (see decode_c0's doc comment for the
// alternatives): named keys win and carry no Ctrl flag, so Ctrl+I is
// indistinguishable from Tab and Ctrl+M from Enter, and 0x08 is Ctrl+h rather
// than Backspace. If any of these change, that is a deliberate policy change
// and this test is the place it must be re-decided.
@(test)
test_c0_policy :: proc(t: ^testing.T) {
	testing.expect_value(t, decode_c0('\r'), Key_Msg{code = .Enter})
	testing.expect_value(t, decode_c0('\n'), Key_Msg{code = .Enter})
	testing.expect_value(t, decode_c0(0x0d), Key_Msg{code = .Enter})   // ctrl+m == enter
	testing.expect_value(t, decode_c0('\t'), Key_Msg{code = .Tab})
	testing.expect_value(t, decode_c0(0x09), Key_Msg{code = .Tab})     // ctrl+i == tab
	testing.expect_value(t, decode_c0(' '),  Key_Msg{code = .Space, r = ' '})
	testing.expect_value(t, decode_c0(0x7f), Key_Msg{code = .Backspace})
	// 0x08 is Ctrl+h, NOT Backspace -- the classic ambiguity, left as-is.
	testing.expect_value(t, decode_c0(0x08), Key_Msg{code = .Rune, r = 'h', mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(0x03), Key_Msg{code = .Rune, r = 'c', mods = {.Ctrl}})
	testing.expect_value(t, decode_c0(0x1a), Key_Msg{code = .Rune, r = 'z', mods = {.Ctrl}})
}

// A modifier parameter out of range must not be forced into a modifier set:
// the sequence is complete, so it is consumed, but nothing is emitted.
// Bits above 8 (Kitty's Hyper/Super/CapsLock/NumLock) are masked off rather
// than mis-reported -- CSI 1;33A is Up with CapsLock, which this decoder
// reports as plain Up.
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

	// Kitty's CapsLock bit (0x20) masked off, not mis-reported.
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
