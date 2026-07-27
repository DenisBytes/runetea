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
// The sequences chosen here are deliberately ones that are OUT of scope
// rather than merely unimplemented: a Kitty keyboard flags report, an SGR
// mouse report, F13 (CSI 25~, beyond the F1-F12 vocabulary Key_Code carries),
// an unassigned tilde parameter, focus in/out and Shift+Tab. The flags report
// is a KEY-level assertion and stays true after T1-K taught the decoder to
// read it: it is never a Key_Msg, and with `enh` omitted (as here, and as
// every caller outside the two event-loop hosts does) it is still consumed
// whole and dropped -- see test_kitty_flags_reply_becomes_an_enhancements_msg
// for the other half.
//
// THE LIST HAS BEEN RETARGETED TWICE, both times for the same reason: a
// sequence that was genuinely unsupported became a feature, and leaving it
// here would have made this test assert the OPPOSITE of the feature. It used
// to use "\e[5~" when the decoder had no tilde table at all (PageUp is decoded
// now), and it used to use "\e[200~" and "\e[201~" until T1-L made bracketed
// paste real -- those two now have their own coverage in the T1-L block below.
// Both times the coverage was moved, not deleted: what this test is FOR is the
// consume-whole-and-emit-nothing contract, and that needs sequences the
// decoder still has no vocabulary for.
@(test)
test_decode_unsupported_csi_is_cleanly_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{"\e[?1u", "\e[<0;10;5M", "\e[25~", "\e[9~", "\e[I", "\e[O", "\e[Z"}) {
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
	// T1-L: how many Paste_Markers the sequence produces. Zero for everything
	// that is not bracketed paste, which is why it is the LAST field -- adding
	// it in the middle would have meant rewriting all 110 positional rows'
	// values, not just appending a 0 to each.
	nmark: int,
}

@(private = "file")
key_cases := [?]Key_Case{
	// -- CSI tilde: navigation ------------------------------------------
	{"\e[1~", {{code = .Home},      {}}, 1, 0},
	{"\e[2~", {{code = .Insert},    {}}, 1, 0},
	{"\e[3~", {{code = .Delete},    {}}, 1, 0},
	{"\e[4~", {{code = .End},       {}}, 1, 0},
	{"\e[5~", {{code = .Page_Up},   {}}, 1, 0},
	{"\e[6~", {{code = .Page_Down}, {}}, 1, 0},
	{"\e[7~", {{code = .Home},      {}}, 1, 0},
	{"\e[8~", {{code = .End},       {}}, 1, 0},

	// -- CSI letter finals ----------------------------------------------
	{"\e[A", {{code = .Up},    {}}, 1, 0},
	{"\e[B", {{code = .Down},  {}}, 1, 0},
	{"\e[C", {{code = .Right}, {}}, 1, 0},
	{"\e[D", {{code = .Left},  {}}, 1, 0},
	{"\e[H", {{code = .Home},  {}}, 1, 0},
	{"\e[F", {{code = .End},   {}}, 1, 0},

	// -- F1-F12, all three encodings ------------------------------------
	// SS3 (what xterm actually sends for F1-F4).
	{"\eOP", {{code = .F1}, {}}, 1, 0},
	{"\eOQ", {{code = .F2}, {}}, 1, 0},
	{"\eOR", {{code = .F3}, {}}, 1, 0},
	{"\eOS", {{code = .F4}, {}}, 1, 0},
	// CSI legacy, bare and with the redundant "1" parameter some terminals
	// emit (linux console, a few terminfo entries).
	{"\e[P",  {{code = .F1}, {}}, 1, 0},
	{"\e[Q",  {{code = .F2}, {}}, 1, 0},
	{"\e[R",  {{code = .F3}, {}}, 1, 0},
	{"\e[S",  {{code = .F4}, {}}, 1, 0},
	{"\e[1P", {{code = .F1}, {}}, 1, 0},
	{"\e[1Q", {{code = .F2}, {}}, 1, 0},
	{"\e[1S", {{code = .F4}, {}}, 1, 0},
	// CSI tilde. 11-14 duplicate F1-F4 on terminals that do not use SS3.
	{"\e[11~", {{code = .F1},  {}}, 1, 0},
	{"\e[12~", {{code = .F2},  {}}, 1, 0},
	{"\e[13~", {{code = .F3},  {}}, 1, 0},
	{"\e[14~", {{code = .F4},  {}}, 1, 0},
	{"\e[15~", {{code = .F5},  {}}, 1, 0},
	{"\e[17~", {{code = .F6},  {}}, 1, 0},
	{"\e[18~", {{code = .F7},  {}}, 1, 0},
	{"\e[19~", {{code = .F8},  {}}, 1, 0},
	{"\e[20~", {{code = .F9},  {}}, 1, 0},
	{"\e[21~", {{code = .F10}, {}}, 1, 0},
	{"\e[23~", {{code = .F11}, {}}, 1, 0},
	{"\e[24~", {{code = .F12}, {}}, 1, 0},

	// -- SS3 arrows (DECCKM application cursor key mode) -----------------
	{"\eOA", {{code = .Up},    {}}, 1, 0},
	{"\eOB", {{code = .Down},  {}}, 1, 0},
	{"\eOC", {{code = .Right}, {}}, 1, 0},
	{"\eOD", {{code = .Left},  {}}, 1, 0},
	{"\eOH", {{code = .Home},  {}}, 1, 0},
	{"\eOF", {{code = .End},   {}}, 1, 0},

	// -- xterm modifier parameters: 1 + bitmask -------------------------
	{"\e[1;5A", {{code = .Up,     mods = {.Ctrl}},          {}}, 1, 0},
	{"\e[1;2C", {{code = .Right,  mods = {.Shift}},         {}}, 1, 0},
	{"\e[3;5~", {{code = .Delete, mods = {.Ctrl}},          {}}, 1, 0},
	{"\e[1;3H", {{code = .Home,   mods = {.Alt}},           {}}, 1, 0},
	{"\e[1;2D", {{code = .Left,   mods = {.Shift}},         {}}, 1, 0},
	{"\e[1;7C", {{code = .Right,  mods = {.Ctrl, .Alt}},    {}}, 1, 0},
	{"\e[1;8B", {{code = .Down,   mods = {.Ctrl, .Alt, .Shift}}, {}}, 1, 0},
	{"\e[1;9A", {{code = .Up,     mods = {.Meta}},          {}}, 1, 0},
	{"\e[1;10D",{{code = .Left,   mods = {.Meta, .Shift}},  {}}, 1, 0},
	{"\e[5;5~", {{code = .Page_Up, mods = {.Ctrl}},         {}}, 1, 0},
	{"\e[15;2~",{{code = .F5,     mods = {.Shift}},         {}}, 1, 0},
	{"\e[1;5P", {{code = .F1,     mods = {.Ctrl}},          {}}, 1, 0},
	{"\e[1;2R", {{code = .F3,     mods = {.Shift}},         {}}, 1, 0},
	{"\e[1;5F", {{code = .End,    mods = {.Ctrl}},          {}}, 1, 0},
	// SS3 with a leading modifier parameter (rare, but xterm emits it for
	// modified F1-F4 in some configurations).
	{"\eO5A", {{code = .Up, mods = {.Ctrl}}, {}}, 1, 0},
	{"\eO2P", {{code = .F1, mods = {.Shift}}, {}}, 1, 0},

	// -- T1-K: Kitty's event-type sub-parameter on the LEGACY encodings --
	//
	// With Report_Event_Types enabled a terminal does NOT move modified arrow
	// and tilde keys to CSI-u; it keeps the legacy form and hangs the event
	// type off the modifier field. Every one of these was a cleanly-ignored
	// sequence before T1-K (csi_params rejects ':' and still does -- these go
	// through csi_event_type's separate stripping pass instead), so the whole
	// block is the non-vacuity lever for that pass: drop it and every row here
	// reports 0 keys instead of 1.
	{"\e[1;5:1A", {{kind = .Press,   code = .Up,    mods = {.Ctrl}}, {}}, 1, 0},
	{"\e[1;5:2A", {{kind = .Repeat,  code = .Up,    mods = {.Ctrl}}, {}}, 1, 0},
	{"\e[1;5:3A", {{kind = .Release, code = .Up,    mods = {.Ctrl}}, {}}, 1, 0},
	{"\e[1;2:3D", {{kind = .Release, code = .Left,  mods = {.Shift}}, {}}, 1, 0},
	{"\e[1;1:2B", {{kind = .Repeat,  code = .Down}, {}}, 1, 0},
	{"\e[3;5:3~", {{kind = .Release, code = .Delete, mods = {.Ctrl}}, {}}, 1, 0},
	{"\e[5;1:2~", {{kind = .Repeat,  code = .Page_Up}, {}}, 1, 0},
	{"\e[15;2:3~",{{kind = .Release, code = .F5,    mods = {.Shift}}, {}}, 1, 0},
	{"\e[1;5:3P", {{kind = .Release, code = .F1,    mods = {.Ctrl}}, {}}, 1, 0},
	// An event type this decoder has no name for is still a real keypress --
	// the SAME answer kitty_decode gives for "\e[97;1:9u", by construction.
	{"\e[1;5:9A", {{kind = .Press,   code = .Up,    mods = {.Ctrl}}, {}}, 1, 0},
	// Present-but-empty sub-parameter: press, again matching "\e[97;1:u".
	{"\e[1;5:A",  {{kind = .Press,   code = .Up,    mods = {.Ctrl}}, {}}, 1, 0},

	// -- T1-J: Kitty keyboard protocol, CSI <code> [;<mods>[:<ev>]] u ---
	//
	// These live in THIS table on purpose: it is what subjects them to
	// test_split_at_every_byte_boundary, and a Kitty sequence is longer than
	// anything else here (up to 12 bytes), so it is the best hold-back
	// exercise in the file.
	//
	// THE WHOLE POINT of the protocol is the pairs below: each legacy
	// collision becomes two distinct byte sequences.
	{"\e[9u",     {{code = .Tab},   {}}, 1, 0},   // Tab
	{"\e[105;5u", {{code = .Rune, r = 'i', mods = {.Ctrl}}, {}}, 1, 0},   // ...vs Ctrl+i
	{"\e[13u",    {{code = .Enter}, {}}, 1, 0},   // Enter
	{"\e[109;5u", {{code = .Rune, r = 'm', mods = {.Ctrl}}, {}}, 1, 0},   // ...vs Ctrl+m
	{"\e[27u",    {{code = .Escape},{}}, 1, 0},   // Escape
	{"\e[91;5u",  {{code = .Rune, r = '[', mods = {.Ctrl}}, {}}, 1, 0},   // ...vs Ctrl+[
	{"\e[8u",     {{code = .Backspace}, {}}, 1, 0},
	{"\e[104;5u", {{code = .Rune, r = 'h', mods = {.Ctrl}}, {}}, 1, 0},   // ...vs Ctrl+h
	{"\e[127u",   {{code = .Backspace}, {}}, 1, 0},

	// Plain and modified text keys.
	{"\e[97u",    {{code = .Rune, r = 'a'}, {}}, 1, 0},
	{"\e[97;5u",  {{code = .Rune, r = 'a', mods = {.Ctrl}}, {}}, 1, 0},
	{"\e[97;3u",  {{code = .Rune, r = 'a', mods = {.Alt}}, {}}, 1, 0},
	{"\e[97;7u",  {{code = .Rune, r = 'a', mods = {.Ctrl, .Alt}}, {}}, 1, 0},
	{"\e[97;8u",  {{code = .Rune, r = 'a', mods = {.Ctrl, .Alt, .Shift}}, {}}, 1, 0},
	{"\e[32u",    {{code = .Space, r = ' '}, {}}, 1, 0},
	{"\e[0u",     {{code = .Space, mods = {.Ctrl}}, {}}, 1, 0},   // Ctrl+Space, no text

	// THE KITTY BITMASK IS NOT THE XTERM BITMASK. Bit 8 is Super in Kitty
	// (Meta in xterm) and bit 32 is Meta in Kitty (nothing in xterm). Decode
	// these with xterm_mods and both lines below flip: ;9u would gain .Meta
	// and ;33u would lose it. That is the non-vacuity lever for kitty_mods.
	{"\e[97;9u",  {{code = .Rune, r = 'a'}, {}}, 1, 0},            // Super: no member, dropped
	{"\e[97;33u", {{code = .Rune, r = 'a', mods = {.Meta}}, {}}, 1, 0},
	{"\e[97;65u", {{code = .Rune, r = 'a'}, {}}, 1, 0},            // CapsLock: dropped
	{"\e[97;129u",{{code = .Rune, r = 'a'}, {}}, 1, 0},            // NumLock: dropped

	// Event types (the ':' sub-parameter on the modifier field).
	{"\e[97;1:1u", {{kind = .Press,   code = .Rune, r = 'a'}, {}}, 1, 0},
	{"\e[97;1:2u", {{kind = .Repeat,  code = .Rune, r = 'a'}, {}}, 1, 0},
	{"\e[97;1:3u", {{kind = .Release, code = .Rune, r = 'a'}, {}}, 1, 0},
	{"\e[97;5:3u", {{kind = .Release, code = .Rune, r = 'a', mods = {.Ctrl}}, {}}, 1, 0},
	{"\e[57352;5:2u", {{kind = .Repeat, code = .Up, mods = {.Ctrl}}, {}}, 1, 0},

	// Functional keycodes: the 57344+ private-use block.
	{"\e[57344u", {{code = .Escape},    {}}, 1, 0},
	{"\e[57345u", {{code = .Enter},     {}}, 1, 0},
	{"\e[57346u", {{code = .Tab},       {}}, 1, 0},
	{"\e[57347u", {{code = .Backspace}, {}}, 1, 0},
	{"\e[57348u", {{code = .Insert},    {}}, 1, 0},
	{"\e[57349u", {{code = .Delete},    {}}, 1, 0},
	{"\e[57350u", {{code = .Left},      {}}, 1, 0},
	{"\e[57351u", {{code = .Right},     {}}, 1, 0},
	{"\e[57352u", {{code = .Up},        {}}, 1, 0},
	{"\e[57353u", {{code = .Down},      {}}, 1, 0},
	{"\e[57354u", {{code = .Page_Up},   {}}, 1, 0},
	{"\e[57355u", {{code = .Page_Down}, {}}, 1, 0},
	{"\e[57356u", {{code = .Home},      {}}, 1, 0},
	{"\e[57357u", {{code = .End},       {}}, 1, 0},
	{"\e[57364u", {{code = .F1},        {}}, 1, 0},
	{"\e[57375u", {{code = .F12},       {}}, 1, 0},
	{"\e[57352;5u", {{code = .Up, mods = {.Ctrl}}, {}}, 1, 0},

	// Alternate key reporting: <key>:<shifted>:<base-layout>. The shifted
	// codepoint is what the keypress actually produces, so it wins for `r`;
	// the base-layout codepoint has nowhere to go and is dropped.
	{"\e[97:65;2u",    {{code = .Rune, r = 'A', mods = {.Shift}}, {}}, 1, 0},
	{"\e[97:65:97;2u", {{code = .Rune, r = 'A', mods = {.Shift}}, {}}, 1, 0},
	{"\e[97::97u",     {{code = .Rune, r = 'a'}, {}}, 1, 0},   // empty shifted sub-param

	// Text-as-codepoints, the third field. One codepoint populates `r`.
	{"\e[97;;98u",   {{code = .Rune, r = 'b'}, {}}, 1, 0},
	{"\e[97;1:1;98u",{{code = .Rune, r = 'b'}, {}}, 1, 0},
	// ...several do not: Key_Msg.r is ONE rune and there is nowhere to put the
	// rest, so the text field is ignored wholesale and `r` falls back to the
	// key code. Documented in kitty_decode; deliberately not a silent truncation.
	{"\e[97;;98:99u", {{code = .Rune, r = 'a'}, {}}, 1, 0},

	// -- T1-L: bracketed paste -------------------------------------------
	//
	// Here for the same reason the Kitty block is: this is the table
	// test_split_at_every_byte_boundary reads, and `\e[200~` is a six-byte
	// introducer whose every proper prefix has to hold back or a paste split
	// across two reads turns into a spurious Escape plus five garbage runes.
	// The richer content cases (a pasted `\e[A`, a nested `\e[200~`, a bare
	// ESC) do not fit `want`'s two slots and live in the T1-L block below.
	{"\e[200~", {{}, {}}, 0, 1},                      // start marker, no keys
	{"\e[200~\e[201~", {{}, {}}, 0, 2},               // empty paste
	{"\e[200~ab\e[201~",
		{{code = .Rune, r = 'a', pasted = true}, {code = .Rune, r = 'b', pasted = true}}, 2, 2},
	// A pasted \n is the CHARACTER, not Enter, and a pasted \t is the
	// character, not Tab -- the whole point of suspending key semantics
	// inside a paste. decode_c0 is never consulted here.
	{"\e[200~\n\t\e[201~",
		{{code = .Rune, r = '\n', pasted = true}, {code = .Rune, r = '\t', pasted = true}}, 2, 2},
	// Multi-byte UTF-8 survives intact; 'é' is 0xC3 0xA9, so this row is also
	// the one that would break first if the paste path decoded byte-wise.
	{"\e[200~é\e[201~", {{code = .Rune, r = 'é', pasted = true}, {}}, 1, 2},

	// -- two sequences back to back -------------------------------------
	{"\e[A\e[1;5D", {{code = .Up}, {code = .Left, mods = {.Ctrl}}}, 2, 0},
	{"\eOA\e[5~",   {{code = .Up}, {code = .Page_Up}}, 2, 0},
	// Kitty and legacy bytes in ONE buffer must both decode (T1-J req. 7).
	{"\e[97;5u\e[A", {{code = .Rune, r = 'a', mods = {.Ctrl}}, {code = .Up}}, 2, 0},
	{"\e[A\e[97u",   {{code = .Up}, {code = .Rune, r = 'a'}}, 2, 0},
}

@(test)
test_decode_key_table :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	// One Paste_State, RESET per row rather than carried: a table row is a
	// self-contained buffer, and "\e[200~" leaving paste mode on would
	// otherwise silently reinterpret every row after it as pasted text --
	// which is exactly the cross-call persistence the T1-L tests below check
	// deliberately, and must not leak in here by accident.
	pst := Paste_State{}; defer delete(pst.markers)
	for c in key_cases {
		clear(&out)
		pst.active = false
		clear(&pst.markers)
		n := decode_keys(transmute([]u8)c.seq, &out, {}, nil, &pst)
		testing.expectf(t, n == len(c.seq), "%q: consumed %d, want %d", c.seq, n, len(c.seq))
		testing.expectf(t, len(pst.markers) == c.nmark,
			"%q: emitted %d paste markers, want %d (%v)", c.seq, len(pst.markers), c.nmark, pst.markers[:])
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
// Only the entries that produce exactly ONE message are split here -- a key,
// or (since T1-L) a lone paste marker. A prefix of a multi-message entry
// legitimately decodes its first sequence, which is a different property (and
// the one test_complete_then_partial checks for keys and
// test_paste_split_at_every_byte_boundary for pastes).
// `checked` guards against the filter silently eating the whole table.
@(test)
test_split_at_every_byte_boundary :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	checked := 0
	for c in key_cases {
		if c.nwant + c.nmark != 1 { continue }
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
	// Floor raised from 100 to 500 when T1-J added the Kitty block, from 500 to
	// 600 when T1-K added the legacy event-type block, and from 600 to 610 when
	// T1-L added "\e[200~" (613 split points at the time of writing, up from
	// 608, up from 531, up from 186). The floor exists so deleting a chunk of
	// the table cannot quietly make this test vacuous, so it has to track the
	// table's actual size.
	testing.expectf(t, checked >= 610, "only %d split points exercised -- table shrank?", checked)
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

// THE DISPATCH TRAP. 'u' is a key final byte, but four other `CSI ... u` forms
// share it and NONE of them is a keypress:
//   CSI ? <flags> u            the flags-query REPLY  (decoded: see below)
//   CSI = <flags> ; <mode> u   set flags
//   CSI > <flags> u            push flags
//   CSI < <n> u                pop flags
// All four carry a private prefix byte (0x3C-0x3F) where a digit belongs, and
// none may ever produce a Key_Msg. A decoder that read the prefix byte as part
// of a parameter would report the flags word as a keypress.
//
// The last three are things a PROGRAM writes -- term.odin writes two of them
// itself -- so one arriving on the INPUT stream is an echo, not information,
// and stays cleanly ignored. The reply is the one the terminal sends, and
// T1-K decodes it; that is a different test, below.
@(test)
test_kitty_non_key_csi_u_forms_are_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	enh := make([dynamic]Keyboard_Enhancements_Msg); defer delete(enh)
	for seq in ([?]string{
		"\e[=1u", "\e[=5;1u", "\e[=0;3u",  // set flags
		"\e[>1u", "\e[>0u",                // push flags   (our own enable sequence, echoed)
		"\e[<1u", "\e[<u",                 // pop flags    (our own teardown sequence, echoed)
		"\e[?u",                           // the QUERY itself -- not a reply, no flags word
		"\e[u",                            // no parameters at all
	}) {
		clear(&out); clear(&enh)
		n := decode_keys(transmute([]u8)seq, &out, {}, &enh)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)",
			seq, len(out), out[:])
		testing.expectf(t, len(enh) == 0, "%q: emitted %d enhancement msgs, want 0",
			seq, len(enh))
	}
}

// T1-K: `CSI ? <flags> u`, the terminal's answer to the `CSI ? u` query
// term_enter_raw sends after pushing. Decoded into a Keyboard_Enhancements_Msg
// so an application can find out what it actually got -- the push itself is
// fire-and-forget, and a terminal may enable fewer flags than were asked for
// (or, with no Kitty support, never reply at all).
@(test)
test_kitty_flags_reply_becomes_an_enhancements_msg :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	enh := make([dynamic]Keyboard_Enhancements_Msg); defer delete(enh)
	Case :: struct { seq: string, want: Kitty_Flags }
	for c in ([?]Case{
		{"\e[?0u",  {}},
		{"\e[?1u",  {.Disambiguate}},
		{"\e[?3u",  {.Disambiguate, .Report_Event_Types}},
		{"\e[?31u", {.Disambiguate, .Report_Event_Types, .Alternate_Keys,
		             .All_Keys_As_Escapes, .Associated_Text}},
		// A bit this decoder has no name for: a newer protocol revision. The
		// known bits still report honestly; the unknown one is dropped rather
		// than transmuted into a Kitty_Flags value with no matching member.
		{"\e[?33u", {.Disambiguate}},
	}) {
		clear(&out); clear(&enh)
		n := decode_keys(transmute([]u8)c.seq, &out, {}, &enh)
		testing.expectf(t, n == len(c.seq), "%q: consumed %d, want %d", c.seq, n, len(c.seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0", c.seq, len(out))
		if !testing.expectf(t, len(enh) == 1, "%q: emitted %d enhancement msgs, want 1",
			c.seq, len(enh)) { continue }
		testing.expectf(t, enh[0].flags == c.want, "%q: flags %v, want %v",
			c.seq, enh[0].flags, c.want)
	}

	// `enh = nil` (the default, and what every caller passed before T1-K) puts
	// the reply straight back on the cleanly-ignored path -- consumed whole,
	// nothing emitted, no nil-deref.
	clear(&out)
	n := decode_keys(transmute([]u8)string("\e[?1u"), &out)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, len(out), 0)

	// It must not swallow neighbouring keys, and a key must not swallow it.
	clear(&out); clear(&enh)
	n = decode_keys(transmute([]u8)string("a\e[?1u\e[A"), &out, {}, &enh)
	testing.expect_value(t, n, 9)
	testing.expect_value(t, len(enh), 1)
	if testing.expect_value(t, len(out), 2) {
		testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = 'a'})
		testing.expect_value(t, out[1], Key_Msg{code = .Up})
	}
}

// The reply is a normal CSI as far as the byte scanner is concerned, so it
// obeys the same HOLD-BACK CONTRACT as every key sequence: every proper prefix
// must consume nothing and emit nothing (bar the documented lone-ESC case).
// It cannot ride in key_cases -- that table's rows are Key_Msg -- so the split
// is done here by hand.
@(test)
test_kitty_flags_reply_holds_back_when_split :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	enh := make([dynamic]Keyboard_Enhancements_Msg); defer delete(enh)
	seq := "\e[?31u"
	b := transmute([]u8)seq
	for k in 1 ..< len(b) {
		clear(&out); clear(&enh)
		n := decode_keys(b[:k], &out, {}, &enh)
		if k == 1 {
			testing.expectf(t, n == 1 && len(out) == 1 && out[0] == Key_Msg{code = .Escape},
				"%q[:1]: got n=%d %v, want the documented lone-ESC resolution", seq, n, out[:])
			continue
		}
		testing.expectf(t, n == 0 && len(out) == 0 && len(enh) == 0,
			"%q[:%d]: got n=%d keys=%v enh=%v, want a complete hold-back",
			seq, k, n, out[:], enh[:])
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

// csi_params ITSELF still rejects ':', which is the load-bearing half of the
// arrangement (read its doc comment). T1-K taught the decoder Kitty's
// event-type extension on the legacy finals -- `CSI 1;5:3A` DOES decode now --
// but it did so with a separate stripping pass (csi_event_type), not by
// widening this parser. Asserted directly, not just through decode_keys,
// because the whole point is that the general parameter parser's contract did
// not move: everything else that carries sub-parameters (SGR colour, SGR
// mouse, DECRPM) still lands on the cleanly-ignored path because of this.
@(test)
test_csi_params_still_rejects_colons :: proc(t: ^testing.T) {
	for p in ([?]string{"1;5:3", "1:2", "38:2::1:2:3", ":", "0;10:5"}) {
		_, _, ok := csi_params(transmute([]u8)p)
		testing.expectf(t, !ok, "csi_params(%q) accepted a ':' sub-parameter", p)
	}
	// ...and the same runs without the ':' are still fine, so the rejection is
	// about the separator and not about the digits around it.
	for p in ([?]string{"1;5", "1", "", "0;10"}) {
		_, _, ok := csi_params(transmute([]u8)p)
		testing.expectf(t, ok, "csi_params(%q) should still parse", p)
	}
}

// Sub-parameter acceptance stays SCOPED: the 'u' final has its own parser
// (kitty_params) and the legacy finals get exactly ONE sub-parameter in
// exactly ONE position (csi_event_type). Anything else with a ':' in it is
// still cleanly ignored rather than half-parsed. Pinning it here so widening
// that later is a conscious act with a failing test attached.
@(test)
test_subparams_are_rejected_outside_csi_u :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{
		"\e[1:2A",     // sub-parameter on the KEY field, not the modifier field
		"\e[1;5:3:4A", // two sub-parameters: not the event-type grammar
		// A non-digit sub-parameter. It has to be a byte in the CSI PARAMETER
		// range (0x30-0x3F) to reach csi_event_type at all -- a letter there
		// would simply be the sequence's final byte, ending the CSI early.
		"\e[1;5:<A",
		"\e[<0;10:5M", // SGR mouse with a stray sub-parameter
		"\e[38:2::1:2:3m", // SGR colour -- many sub-parameters, not a key at all
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

// ---------------------------------------------------------------------------
// T1-L: bracketed paste.
//
// The correctness crux is that INSIDE a paste the bytes are TEXT, not keys:
// no escape-sequence decoding (a pasted "\e[A" is three literal runes, never
// Up) and no key semantics (a pasted "\n" is the character, never Enter). The
// table below is written as "what runes should come out", so every row is a
// direct statement of that property.
// ---------------------------------------------------------------------------

@(private = "file")
Paste_Case :: struct {
	name:   string,
	seq:    string,
	// The pasted TEXT, as the runes that must come out in order. Every one of
	// them must arrive as Key_Msg{code = .Rune, r = <it>, pasted = true}.
	text:   string,
	marks:  [2]Paste_Marker,
	nmark:  int,
}

@(private = "file")
paste_cases := [?]Paste_Case{
	{"complete paste", "\e[200~hello\e[201~", "hello",
		{{at = 0, start = true}, {at = 5}}, 2},

	// THE HEADLINE BUG. Without bracketed paste, pasting a buffer that happens
	// to contain "\e[A" executes an Up arrow in the middle of the text.
	{"escape sequence is literal text", "\e[200~x\e[Ay\e[201~", "x\e[Ay",
		{{at = 0, start = true}, {at = 5}}, 2},

	// Key semantics are suspended too: an app inserting pasted text wants a
	// newline CHARACTER in its buffer, not "the user pressed Enter". Same for
	// \t (not Tab) and \r (not Enter).
	{"newline, tab and CR are literal runes", "\e[200~a\n\t\rb\e[201~", "a\n\t\rb",
		{{at = 0, start = true}, {at = 5}}, 2},

	// Multi-byte UTF-8 must come through intact -- the paste path does its own
	// rune decoding rather than emitting bytes.
	{"multi-byte utf-8", "\e[200~héllo→\e[201~", "héllo→",
		{{at = 0, start = true}, {at = 6}}, 2},

	// Zero-length paste. This is the case that makes the markers necessary at
	// all: with no keys between them there is nothing else for an application
	// to notice the paste by.
	{"empty paste", "\e[200~\e[201~", "",
		{{at = 0, start = true}, {at = 0}}, 2},

	// ONLY "\e[201~" ends a paste. xterm filters ESC out of paste content, but
	// this decoder does not assume that: a bare ESC that is not the terminator
	// is literal text.
	{"bare ESC inside a paste is literal", "\e[200~a\e\e[201~", "a\e",
		{{at = 0, start = true}, {at = 2}}, 2},

	// ...and so is a nested "\e[200~": all six of its bytes are runes. A
	// decoder that re-entered paste mode here would swallow the real
	// terminator and never leave.
	{"nested paste start is literal", "\e[200~a\e[200~b\e[201~", "a\e[200~b",
		{{at = 0, start = true}, {at = 8}}, 2},

	// A near-miss terminator: "\e[201X" is not "\e[201~", so every byte of it
	// is text and the paste keeps going.
	{"near-miss terminator is literal", "\e[200~\e[201X\e[201~", "\e[201X",
		{{at = 0, start = true}, {at = 6}}, 2},
}

// Feeds `data` through decode_keys exactly the way the reader loops do
// (tea.odin, loop_nbio.odin): append to a pending buffer, decode, drop what
// was consumed, keep the rest for the next chunk. Returns nothing -- the
// caller inspects `out`, `pst` and `pending` itself.
@(private = "file")
paste_feed :: proc(pending: ^[dynamic]u8, chunk: []u8, out: ^[dynamic]Key_Msg, pst: ^Paste_State) {
	append(pending, ..chunk)
	consumed := decode_keys(pending[:], out, {}, nil, pst)
	if consumed > 0 { remove_range(pending, 0, consumed) }
}

// Asserts that `out`/`pst` hold exactly what `c` says they should.
@(private = "file")
paste_check :: proc(t: ^testing.T, c: Paste_Case, label: string, out: []Key_Msg, pst: ^Paste_State) {
	i := 0
	for r in c.text {
		if !testing.expectf(t, i < len(out), "%s/%s: ran out of keys at rune %d (%v)",
			c.name, label, i, out) { return }
		want := Key_Msg{code = .Rune, r = r, pasted = true}
		testing.expectf(t, out[i] == want, "%s/%s: key %d = %v, want %v",
			c.name, label, i, out[i], want)
		i += 1
	}
	testing.expectf(t, len(out) == i, "%s/%s: emitted %d keys, want %d (%v)",
		c.name, label, len(out), i, out)
	if !testing.expectf(t, len(pst.markers) == c.nmark, "%s/%s: %d markers, want %d (%v)",
		c.name, label, len(pst.markers), c.nmark, pst.markers[:]) { return }
	for k in 0 ..< c.nmark {
		testing.expectf(t, pst.markers[k] == c.marks[k], "%s/%s: marker %d = %v, want %v",
			c.name, label, k, pst.markers[k], c.marks[k])
	}
	testing.expectf(t, !pst.active, "%s/%s: paste mode still active after the terminator", c.name, label)
}

@(test)
test_bracketed_paste_table :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pending: [dynamic]u8; defer delete(pending)
	pst := Paste_State{}; defer delete(pst.markers)

	for c in paste_cases {
		clear(&out); clear(&pending); clear(&pst.markers); pst.active = false
		paste_feed(&pending, transmute([]u8)c.seq, &out, &pst)
		testing.expectf(t, len(pending) == 0, "%s: %d bytes left unconsumed", c.name, len(pending))
		paste_check(t, c, "whole", out[:], &pst)
	}
}

// THE STREAMING TEST, and the one that pins paste mode as decoder STATE.
//
// Every case is split at every byte boundary into two chunks fed through ONE
// Paste_State, which is exactly what the reader does when a paste straddles a
// read: decode_keys is called once per read, so paste mode has to survive the
// gap. The result must be byte-for-byte what the whole buffer produced -- a
// paste that stalled (held back its content) or that lost its mode across the
// call boundary both show up here immediately.
@(test)
test_paste_split_at_every_byte_boundary :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pending: [dynamic]u8; defer delete(pending)
	pst := Paste_State{}; defer delete(pst.markers)
	checked := 0

	for c in paste_cases {
		b := transmute([]u8)c.seq
		for k in 1 ..< len(b) {
			clear(&out); clear(&pending); clear(&pst.markers); pst.active = false

			if k == 1 {
				// THE ONE EXCEPTION, and it is not a paste exception: a first
				// chunk of exactly "\e" is the documented lone-ESC ambiguity
				// (decode_keys' doc comment), resolved as Escape because there
				// is no timer to tell "sequence in flight" from "key pressed".
				// Bracketed paste does not change that, and the introducer's
				// ESC is not special -- test_split_at_every_byte_boundary pins
				// the same answer for every other sequence in the decoder.
				// Asserted positively rather than skipped, so the exception
				// stays visible.
				paste_feed(&pending, b[:1], &out, &pst)
				testing.expectf(t, len(out) == 1 && out[0] == Key_Msg{code = .Escape},
					"%s[:1]: got %v, want the documented lone-ESC resolution", c.name, out[:])
				testing.expectf(t, len(pending) == 0, "%s[:1]: %d bytes left unconsumed",
					c.name, len(pending))
				continue
			}

			checked += 1
			paste_feed(&pending, b[:k], &out, &pst)
			paste_feed(&pending, b[k:], &out, &pst)
			testing.expectf(t, len(pending) == 0,
				"%s[:%d]: %d bytes left unconsumed", c.name, k, len(pending))
			paste_check(t, c, "split", out[:], &pst)
		}
	}
	// Anti-vacuity floor, same purpose as test_split_at_every_byte_boundary's:
	// 121 split points across the 8 cases at the time of writing (129 boundaries
	// less the 8 lone-ESC ones handled above).
	testing.expectf(t, checked >= 115, "only %d split points exercised -- table shrank?", checked)
}

// The content of a paste must NOT be held back: it is streamed out as it
// arrives, or a large paste would sit in the reader's `pending` buffer
// unboundedly, which is the whole reason this feature streams rather than
// accumulating. Only a partial UTF-8 rune or a partial terminator may stall.
@(test)
test_paste_content_is_streamed_not_buffered :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pending: [dynamic]u8; defer delete(pending)
	pst := Paste_State{}; defer delete(pst.markers)

	// Start plus 1000 bytes of content, no terminator in sight.
	body: [dynamic]u8; defer delete(body)
	append(&body, ..transmute([]u8)string("\e[200~"))
	for _ in 0 ..< 1000 { append(&body, 'x') }
	paste_feed(&pending, body[:], &out, &pst)
	testing.expect_value(t, len(pending), 0)
	testing.expect_value(t, len(out), 1000)
	testing.expect(t, pst.active, "still inside the paste")
	testing.expect_value(t, len(pst.markers), 1)

	// The only things that may stall: a partial UTF-8 rune...
	clear(&out)
	paste_feed(&pending, []u8{0xC3}, &out, &pst)
	testing.expectf(t, len(out) == 0 && len(pending) == 1,
		"a split UTF-8 rune inside a paste must hold back: %d keys, %d pending", len(out), len(pending))
	paste_feed(&pending, []u8{0xA9}, &out, &pst)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = 'é', pasted = true})

	// ...and a partial terminator. A BARE ESC AT THE END OF THE BUFFER HOLDS
	// BACK inside a paste, unlike the lone-ESC rule at top level: both readings
	// (terminator in flight, literal ESC in the text) are text, so there is no
	// keypress to lose by waiting -- whereas resolving it as text would eat the
	// real terminator's first byte and strand the decoder in paste mode
	// forever. See decode_keys' doc comment.
	clear(&out)
	paste_feed(&pending, transmute([]u8)string("\e[20"), &out, &pst)
	testing.expectf(t, len(out) == 0 && len(pending) == 4,
		"a partial terminator must hold back: %d keys, %d pending", len(out), len(pending))
	paste_feed(&pending, transmute([]u8)string("1~"), &out, &pst)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, len(pending), 0)
	testing.expect(t, !pst.active, "the terminator must end paste mode")
}

// Paste mode is state that persists across decode_keys calls -- the reader
// calls it once per read, so a paste spanning two reads is the normal case,
// not the edge case.
@(test)
test_paste_state_persists_across_decode_keys_calls :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pst := Paste_State{}; defer delete(pst.markers)

	n := decode_keys(transmute([]u8)string("\e[200~ab"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 8)
	testing.expect(t, pst.active, "paste mode must survive the end of the call")
	testing.expect_value(t, len(out), 2)

	// A SEPARATE call: "\e[A" here is pasted text, not Up.
	n = decode_keys(transmute([]u8)string("\e[Ac\e[201~"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 10)
	testing.expect(t, !pst.active, "the terminator must end paste mode")
	if testing.expect_value(t, len(out), 6) {
		for r, i in "ab\e[Ac" {
			testing.expect_value(t, out[i], Key_Msg{code = .Rune, r = r, pasted = true})
		}
	}
	if testing.expect_value(t, len(pst.markers), 2) {
		testing.expect_value(t, pst.markers[0], Paste_Marker{at = 0, start = true})
		testing.expect_value(t, pst.markers[1], Paste_Marker{at = 6})
	}

	// A key AFTER the paste is an ordinary key again: pasted = false, and
	// "\e[A" decodes as Up once more.
	clear(&out); clear(&pst.markers)
	n = decode_keys(transmute([]u8)string("\e[A"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})
}

// `pst = nil` (the default, and what every caller before T1-L passed) is the
// same degradation `enh = nil` is: the sequences are still understood WITHIN
// one buffer, but there is nowhere to record the markers and nowhere for the
// mode to live between calls. Pinned rather than left implicit, because a
// caller that wants paste across reads has to pass a Paste_State and this is
// what happens if it forgets.
@(test)
test_paste_without_a_state_does_not_persist :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)

	// Within one buffer it still works: the "\e[A" is text.
	n := decode_keys(transmute([]u8)string("\e[200~\e[A\e[201~"), &out)
	testing.expect_value(t, n, 15)
	if testing.expect_value(t, len(out), 3) {
		for r, i in "\e[A" {
			testing.expect_value(t, out[i], Key_Msg{code = .Rune, r = r, pasted = true})
		}
	}

	// Across two calls it does not: the second call starts outside paste mode.
	clear(&out)
	decode_keys(transmute([]u8)string("\e[200~a"), &out)
	clear(&out)
	decode_keys(transmute([]u8)string("\e[A"), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})
}

// An END with no START is cleanly ignored, NOT reported as a Paste_End_Msg.
// Emitting one would tell an application to leave a mode it never entered --
// the same class of hazard as the Kitty double-pop (term.odin), one layer up.
@(test)
test_unpaired_paste_end_is_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pst := Paste_State{}; defer delete(pst.markers)

	n := decode_keys(transmute([]u8)string("\e[201~"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, len(pst.markers), 0)
	testing.expect(t, !pst.active, "an unpaired end must not enter paste mode")

	// A trailing extra terminator after a real paste is the same thing.
	clear(&pst.markers)
	n = decode_keys(transmute([]u8)string("\e[200~a\e[201~\e[201~"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 19)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, len(pst.markers), 2)
}

// An UNTERMINATED paste (the terminal dies, or is buggy, mid-paste) must not
// wedge anything: everything decodable is still consumed and emitted, only an
// ambiguous tail of at most five bytes (a proper prefix of the terminator) is
// held back, and the reader keeps making progress until its read() reports
// EOF. Documented in decode_keys; asserted here so "bounded" is a fact.
@(test)
test_unterminated_paste_does_not_wedge_the_reader :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pending: [dynamic]u8; defer delete(pending)
	pst := Paste_State{}; defer delete(pst.markers)

	paste_feed(&pending, transmute([]u8)string("\e[200~hello"), &out, &pst)
	testing.expect_value(t, len(pending), 0)
	testing.expect_value(t, len(out), 5)

	// More text keeps flowing, still as pasted text, still fully consumed.
	clear(&out)
	paste_feed(&pending, transmute([]u8)string(" world"), &out, &pst)
	testing.expect_value(t, len(pending), 0)
	testing.expect_value(t, len(out), 6)
	testing.expect(t, pst.active, "no terminator arrived, so paste mode stays on")

	// The worst case for `pending` is a full proper prefix of the terminator:
	// five bytes, and it can never grow past that.
	clear(&out)
	paste_feed(&pending, transmute([]u8)string("\e[201"), &out, &pst)
	testing.expect_value(t, len(pending), 5)
	clear(&out)
	paste_feed(&pending, transmute([]u8)string("X\e[201"), &out, &pst)
	testing.expectf(t, len(pending) == 5, "pending grew to %d -- it must stay bounded", len(pending))
	testing.expect_value(t, len(out), 6)   // "\e[201X" resynchronised as literal text
}

// Paste_Start_Msg and Paste_End_Msg cross the mailbox like every other Msg, so
// they are subject to box()'s MESSAGE OWNERSHIP CONTRACT (arena.odin). They
// are zero-sized structs precisely so they can be: Bubble Tea's
// PasteMsg{Content string} would be rejected here, which is why RuneTea
// streams the content as ordinary Key_Msgs instead of accumulating it.
@(test)
test_paste_msgs_are_pod :: proc(t: ^testing.T) {
	testing.expect(t, is_pod_type(Paste_Start_Msg), "Paste_Start_Msg must be POD")
	testing.expect(t, is_pod_type(Paste_End_Msg), "Paste_End_Msg must be POD")
	testing.expect(t, is_pod_type(Key_Msg), "Key_Msg must stay POD after gaining `pasted`")
	testing.expect_value(t, size_of(Paste_Start_Msg), 0)
	testing.expect_value(t, size_of(Paste_End_Msg), 0)
}
