#+private
// ^ Every declaration in this file is package-private, so that `odin doc
//   runetea` / `odin doc runegloss` -- the command README.md and docs/API.md
//   hand a newcomer for symbol discovery -- lists the library rather than the
//   test fixtures. Pinned by tools/doccheck/run.sh's `apidoc` check, which is
//   also where the argument for it is written out.
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
// rather than merely unimplemented: a Kitty keyboard flags report, F13 (CSI
// 25~, beyond the F1-F12 vocabulary Key_Code carries), an unassigned tilde
// parameter, Shift+Tab, Begin, a DECRPM mode report, an xterm
// modifyOtherKeys report, a colour-scheme report, a PARAMETERISED 'I' (which
// is not the focus grammar), and an SGR-prefixed sequence whose final byte is
// neither 'M' nor 'm'. The flags report is a KEY-level assertion and stays true
// after T1-K taught the decoder to read it: it is never a Key_Msg, and with
// `enh` omitted (as here, and as every caller outside the two event-loop hosts
// does) it is still consumed whole and dropped -- see
// test_kitty_flags_reply_becomes_an_enhancements_msg for the other half.
//
// THE LIST HAS NOW BEEN RETARGETED THREE TIMES, every time for the same
// reason: a sequence that was genuinely unsupported became a feature, and
// leaving it here would have made this test assert the OPPOSITE of the feature.
// It used to use "\e[5~" when the decoder had no tilde table at all (PageUp is
// decoded now); it used to use "\e[200~" and "\e[201~" until T1-L made
// bracketed paste real; and T2-B has just taken "\e[<0;10;5M" (SGR mouse),
// "\e[I" and "\e[O" (focus in/out), all three of which are now decoded and
// covered by the T2-B block at the bottom of this file. Every time the coverage
// was MOVED, not deleted: what this test is FOR is the
// consume-whole-and-emit-nothing contract, and that needs sequences the decoder
// still has no vocabulary for.
//
// The last two entries are the T2-B-shaped replacements specifically. "\e[1I"
// proves the focus grammar is parameterless -- a decoder that matched on the
// final byte alone would report a focus event for it -- and "\e[<0;10;5t"
// proves the '<' private-prefix path is scoped to the two mouse finals rather
// than to the prefix.
@(test)
test_decode_unsupported_csi_is_cleanly_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{
		// "\e[Z" USED TO BE ON THIS LIST and was moved off it deliberately: it
		// is Shift+Tab (kcbt), present in 21 of the 40 terminfo entries on this
		// machine including xterm, tmux, screen and rxvt, and it is now decoded.
		// See test_shift_tab_decodes_from_csi_z.
		"\e[?1u", "\e[25~", "\e[9~", "\e[E",
		"\e[?2004;1$y",     // DECRPM report (carries an intermediate byte)
		"\e[>4;2m",         // xterm modifyOtherKeys report: 'm' final, but a '>' prefix
		"\e[?997;1n",       // light/dark colour-scheme report
		"\e[1I",            // NOT focus-in: the focus grammar takes no parameters
		"\e[<0;10;5t",      // SGR prefix, but not a mouse final byte
	}) {
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
	// How many Input_Markers the sequence produces. Zero for everything
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

	// -- T2-B: mouse and focus -------------------------------------------
	//
	// Here for the same reason the Kitty and paste blocks are: this is the table
	// test_split_at_every_byte_boundary reads, and both mouse encodings have to
	// obey the HOLD-BACK CONTRACT byte for byte. The legacy rows are the
	// important ones -- their last three bytes are NOT part of CSI grammar and
	// can be any byte at all, so every proper prefix of them must hold back
	// completely. WHAT each of these decodes to is asserted in
	// test_mouse_decode_table below; what is asserted HERE is only that the
	// sequence is consumed whole and produces exactly one marker and no keys.
	{"\e[<0;10;5M",  {{}, {}}, 0, 1},   // SGR press
	{"\e[<0;10;5m",  {{}, {}}, 0, 1},   // SGR release
	{"\e[<32;10;5M", {{}, {}}, 0, 1},   // SGR drag
	{"\e[<64;10;5M", {{}, {}}, 0, 1},   // SGR wheel up
	{"\e[<65;10;5M", {{}, {}}, 0, 1},   // SGR wheel down
	{"\e[<20;10;5M", {{}, {}}, 0, 1},   // SGR ctrl+shift+left press
	{"\e[<0;300;5M", {{}, {}}, 0, 1},   // a column the legacy encoding cannot express
	// Legacy/X10. Six bytes, the last three RAW: "\e[M" then Cb+32, Cx+32,
	// Cy+32. ' ' is Cb 0 (left press), '*' is column 10, '%' is row 5.
	{"\e[M *%",      {{}, {}}, 0, 1},   // legacy press
	{"\e[M#*%",      {{}, {}}, 0, 1},   // legacy release ('#' is Cb 3)
	// THE PAYLOAD TRAP, twice. A raw byte of 0x1B must NOT be read as an escape
	// introducer, and raw bytes of 'M' / '~' must not be read as CSI final
	// bytes -- in either case the decoder would resolve a phantom sequence and
	// eat the user's next real keystroke. Splitting these at every boundary is
	// what proves the three bytes are never fed back to the scanner.
	{"\e[M *\e",     {{}, {}}, 0, 1},   // 0x1B as the Cy byte
	{"\e[M M~",      {{}, {}}, 0, 1},   // 'M' as Cx, '~' as Cy
	// Focus in / out.
	{"\e[I", {{}, {}}, 0, 1},
	{"\e[O", {{}, {}}, 0, 1},

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
	// One Input_State, RESET per row rather than carried: a table row is a
	// self-contained buffer, and "\e[200~" leaving paste mode on would
	// otherwise silently reinterpret every row after it as pasted text --
	// which is exactly the cross-call persistence the T1-L tests below check
	// deliberately, and must not leak in here by accident.
	pst := Input_State{}; defer delete(pst.markers)
	for c in key_cases {
		clear(&out)
		pst.in_paste = false
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
	// 600 when T1-K added the legacy event-type block, from 600 to 610 when
	// T1-L added "\e[200~", and from 610 to 700 when T2-B added the mouse and
	// focus rows (705 split points at the time of writing, up from 613, up from
	// 608, up from 531, up from 186). The floor exists so deleting a chunk of
	// the table cannot quietly make this test vacuous, so it has to track the
	// table's actual size.
	testing.expectf(t, checked >= 700, "only %d split points exercised -- table shrank?", checked)
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
	marks:  [2]Input_Marker,
	nmark:  int,
}

@(private = "file")
paste_cases := [?]Paste_Case{
	{"complete paste", "\e[200~hello\e[201~", "hello",
		{{at = 0, kind = .Paste_Start}, {at = 5, kind = .Paste_End}}, 2},

	// THE HEADLINE BUG. Without bracketed paste, pasting a buffer that happens
	// to contain "\e[A" executes an Up arrow in the middle of the text.
	{"escape sequence is literal text", "\e[200~x\e[Ay\e[201~", "x\e[Ay",
		{{at = 0, kind = .Paste_Start}, {at = 5, kind = .Paste_End}}, 2},

	// Key semantics are suspended too: an app inserting pasted text wants a
	// newline CHARACTER in its buffer, not "the user pressed Enter". Same for
	// \t (not Tab) and \r (not Enter).
	{"newline, tab and CR are literal runes", "\e[200~a\n\t\rb\e[201~", "a\n\t\rb",
		{{at = 0, kind = .Paste_Start}, {at = 5, kind = .Paste_End}}, 2},

	// Multi-byte UTF-8 must come through intact -- the paste path does its own
	// rune decoding rather than emitting bytes.
	{"multi-byte utf-8", "\e[200~héllo→\e[201~", "héllo→",
		{{at = 0, kind = .Paste_Start}, {at = 6, kind = .Paste_End}}, 2},

	// Zero-length paste. This is the case that makes the markers necessary at
	// all: with no keys between them there is nothing else for an application
	// to notice the paste by.
	{"empty paste", "\e[200~\e[201~", "",
		{{at = 0, kind = .Paste_Start}, {at = 0, kind = .Paste_End}}, 2},

	// ONLY "\e[201~" ends a paste. xterm filters ESC out of paste content, but
	// this decoder does not assume that: a bare ESC that is not the terminator
	// is literal text.
	{"bare ESC inside a paste is literal", "\e[200~a\e\e[201~", "a\e",
		{{at = 0, kind = .Paste_Start}, {at = 2, kind = .Paste_End}}, 2},

	// ...and so is a nested "\e[200~": all six of its bytes are runes. A
	// decoder that re-entered paste mode here would swallow the real
	// terminator and never leave.
	{"nested paste start is literal", "\e[200~a\e[200~b\e[201~", "a\e[200~b",
		{{at = 0, kind = .Paste_Start}, {at = 8, kind = .Paste_End}}, 2},

	// A near-miss terminator: "\e[201X" is not "\e[201~", so every byte of it
	// is text and the paste keeps going.
	{"near-miss terminator is literal", "\e[200~\e[201X\e[201~", "\e[201X",
		{{at = 0, kind = .Paste_Start}, {at = 6, kind = .Paste_End}}, 2},
}

// Feeds `data` through decode_keys exactly the way the reader loops do
// (tea.odin, loop_nbio.odin): append to a pending buffer, decode, drop what
// was consumed, keep the rest for the next chunk. Returns nothing -- the
// caller inspects `out`, `pst` and `pending` itself.
@(private = "file")
paste_feed :: proc(pending: ^[dynamic]u8, chunk: []u8, out: ^[dynamic]Key_Msg, pst: ^Input_State) {
	append(pending, ..chunk)
	consumed := decode_keys(pending[:], out, {}, nil, pst)
	if consumed > 0 { remove_range(pending, 0, consumed) }
}

// Asserts that `out`/`pst` hold exactly what `c` says they should.
@(private = "file")
paste_check :: proc(t: ^testing.T, c: Paste_Case, label: string, out: []Key_Msg, pst: ^Input_State) {
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
	testing.expectf(t, !pst.in_paste, "%s/%s: paste mode still active after the terminator", c.name, label)
}

@(test)
test_bracketed_paste_table :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pending: [dynamic]u8; defer delete(pending)
	pst := Input_State{}; defer delete(pst.markers)

	for c in paste_cases {
		clear(&out); clear(&pending); clear(&pst.markers); pst.in_paste = false
		paste_feed(&pending, transmute([]u8)c.seq, &out, &pst)
		testing.expectf(t, len(pending) == 0, "%s: %d bytes left unconsumed", c.name, len(pending))
		paste_check(t, c, "whole", out[:], &pst)
	}
}

// THE STREAMING TEST, and the one that pins paste mode as decoder STATE.
//
// Every case is split at every byte boundary into two chunks fed through ONE
// Input_State, which is exactly what the reader does when a paste straddles a
// read: decode_keys is called once per read, so paste mode has to survive the
// gap. The result must be byte-for-byte what the whole buffer produced -- a
// paste that stalled (held back its content) or that lost its mode across the
// call boundary both show up here immediately.
@(test)
test_paste_split_at_every_byte_boundary :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pending: [dynamic]u8; defer delete(pending)
	pst := Input_State{}; defer delete(pst.markers)
	checked := 0

	for c in paste_cases {
		b := transmute([]u8)c.seq
		for k in 1 ..< len(b) {
			clear(&out); clear(&pending); clear(&pst.markers); pst.in_paste = false

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
	pst := Input_State{}; defer delete(pst.markers)

	// Start plus 1000 bytes of content, no terminator in sight.
	body: [dynamic]u8; defer delete(body)
	append(&body, ..transmute([]u8)string("\e[200~"))
	for _ in 0 ..< 1000 { append(&body, 'x') }
	paste_feed(&pending, body[:], &out, &pst)
	testing.expect_value(t, len(pending), 0)
	testing.expect_value(t, len(out), 1000)
	testing.expect(t, pst.in_paste, "still inside the paste")
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
	testing.expect(t, !pst.in_paste, "the terminator must end paste mode")
}

// Paste mode is state that persists across decode_keys calls -- the reader
// calls it once per read, so a paste spanning two reads is the normal case,
// not the edge case.
@(test)
test_paste_state_persists_across_decode_keys_calls :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pst := Input_State{}; defer delete(pst.markers)

	n := decode_keys(transmute([]u8)string("\e[200~ab"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 8)
	testing.expect(t, pst.in_paste, "paste mode must survive the end of the call")
	testing.expect_value(t, len(out), 2)

	// A SEPARATE call: "\e[A" here is pasted text, not Up.
	n = decode_keys(transmute([]u8)string("\e[Ac\e[201~"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 10)
	testing.expect(t, !pst.in_paste, "the terminator must end paste mode")
	if testing.expect_value(t, len(out), 6) {
		for r, i in "ab\e[Ac" {
			testing.expect_value(t, out[i], Key_Msg{code = .Rune, r = r, pasted = true})
		}
	}
	if testing.expect_value(t, len(pst.markers), 2) {
		testing.expect_value(t, pst.markers[0], Input_Marker{at = 0, kind = .Paste_Start})
		testing.expect_value(t, pst.markers[1], Input_Marker{at = 6, kind = .Paste_End})
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
// caller that wants paste across reads has to pass a Input_State and this is
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
	pst := Input_State{}; defer delete(pst.markers)

	n := decode_keys(transmute([]u8)string("\e[201~"), &out, {}, nil, &pst)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, len(pst.markers), 0)
	testing.expect(t, !pst.in_paste, "an unpaired end must not enter paste mode")

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
	pst := Input_State{}; defer delete(pst.markers)

	paste_feed(&pending, transmute([]u8)string("\e[200~hello"), &out, &pst)
	testing.expect_value(t, len(pending), 0)
	testing.expect_value(t, len(out), 5)

	// More text keeps flowing, still as pasted text, still fully consumed.
	clear(&out)
	paste_feed(&pending, transmute([]u8)string(" world"), &out, &pst)
	testing.expect_value(t, len(pending), 0)
	testing.expect_value(t, len(out), 6)
	testing.expect(t, pst.in_paste, "no terminator arrived, so paste mode stays on")

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

// ---------------------------------------------------------------------------
// T2-B: mouse reporting and focus events.
//
// The decoded VALUES live here; the byte-level hold-back contract lives in
// key_cases (see the T2-B block there) so that every sequence added to the
// decoder's vocabulary is automatically split at every boundary too.
// ---------------------------------------------------------------------------

@(private = "file")
Mouse_Case :: struct {
	name: string,
	seq:  string,
	want: Mouse_Msg,
}

@(private = "file")
mouse_cases := [?]Mouse_Case{
	// -- SGR: CSI < Cb ; Cx ; Cy M|m -------------------------------------
	//
	// Coordinates on the wire are ONE-based and (10,5) is therefore cell (9,4).
	// Every row below uses the same coordinates so that a mistake in the
	// button/modifier decoding cannot hide behind a coordinate difference.
	{"sgr press left",    "\e[<0;10;5M",  {kind = .Press,  button = .Left,   x = 9, y = 4}},
	{"sgr press middle",  "\e[<1;10;5M",  {kind = .Press,  button = .Middle, x = 9, y = 4}},
	{"sgr press right",   "\e[<2;10;5M",  {kind = .Press,  button = .Right,  x = 9, y = 4}},
	// THE ONE THING THE LEGACY ENCODING CANNOT DO: the final byte, not the
	// button bits, says press vs release, so the button survives a release.
	{"sgr release left",  "\e[<0;10;5m",  {kind = .Release, button = .Left,  x = 9, y = 4}},
	{"sgr release right", "\e[<2;10;5m",  {kind = .Release, button = .Right, x = 9, y = 4}},

	// Motion bit (32) with a button held: a drag, which is what DECSET 1002 is
	// for. Reported as .Motion with the held button, not as a second press.
	{"sgr drag left",   "\e[<32;10;5M", {kind = .Motion, button = .Left,  x = 9, y = 4}},
	{"sgr drag right",  "\e[<34;10;5M", {kind = .Motion, button = .Right, x = 9, y = 4}},
	// Motion with NO button (Cb bits 0-1 == 3): what DECSET 1003 floods the
	// stream with. .None is a real answer here, not a placeholder.
	{"sgr motion, no button", "\e[<35;10;5M", {kind = .Motion, button = .None, x = 9, y = 4}},

	// Wheel bank (bit 64). The motion bit is deliberately NOT honoured for
	// these -- terminals set it spuriously and a "wheel drag" is not a thing --
	// so 64 and 96 must decode identically.
	{"sgr wheel up",    "\e[<64;10;5M", {kind = .Wheel, button = .Wheel_Up,    x = 9, y = 4}},
	{"sgr wheel down",  "\e[<65;10;5M", {kind = .Wheel, button = .Wheel_Down,  x = 9, y = 4}},
	{"sgr wheel left",  "\e[<66;10;5M", {kind = .Wheel, button = .Wheel_Left,  x = 9, y = 4}},
	{"sgr wheel right", "\e[<67;10;5M", {kind = .Wheel, button = .Wheel_Right, x = 9, y = 4}},
	{"sgr wheel up with the motion bit set",
		"\e[<96;10;5M", {kind = .Wheel, button = .Wheel_Up, x = 9, y = 4}},

	// Modifiers. Bit 4 Shift, bit 8 "meta" (reported as .Alt -- see
	// mouse_button_bits), bit 16 Ctrl. .Meta is never set by a mouse report.
	{"sgr shift+left",  "\e[<4;10;5M",  {kind = .Press, button = .Left, x = 9, y = 4, mods = {.Shift}}},
	{"sgr alt+left",    "\e[<8;10;5M",  {kind = .Press, button = .Left, x = 9, y = 4, mods = {.Alt}}},
	{"sgr ctrl+left",   "\e[<16;10;5M", {kind = .Press, button = .Left, x = 9, y = 4, mods = {.Ctrl}}},
	{"sgr ctrl+shift+left",
		"\e[<20;10;5M", {kind = .Press, button = .Left, x = 9, y = 4, mods = {.Ctrl, .Shift}}},
	{"sgr all three mods on the right button",
		"\e[<30;10;5M", {kind = .Press, button = .Right, x = 9, y = 4, mods = {.Ctrl, .Alt, .Shift}}},
	{"sgr ctrl+wheel down",
		"\e[<81;10;5M", {kind = .Wheel, button = .Wheel_Down, x = 9, y = 4, mods = {.Ctrl}}},
	{"sgr modifiers survive a release",
		"\e[<18;10;5m", {kind = .Release, button = .Right, x = 9, y = 4, mods = {.Ctrl}}},

	// The extra-button bank (bit 128): browser back/forward and two unnamed
	// buttons. Mouse_Button carries all four, so nothing is lost.
	{"sgr backward",  "\e[<128;10;5M", {kind = .Press, button = .Backward,  x = 9, y = 4}},
	{"sgr forward",   "\e[<129;10;5M", {kind = .Press, button = .Forward,   x = 9, y = 4}},
	{"sgr button 11", "\e[<131;10;5M", {kind = .Press, button = .Button_11, x = 9, y = 4}},

	// THE CASE LEGACY CANNOT EXPRESS, and the entire reason term_enter_raw asks
	// for `?1006h`: a column past 223. In the legacy encoding Cx+32 would have
	// to be byte 332, which does not exist.
	{"sgr column past 223",  "\e[<0;300;5M",  {kind = .Press, button = .Left, x = 299, y = 4}},
	{"sgr row past 223",     "\e[<0;10;400M", {kind = .Press, button = .Left, x = 9, y = 399}},
	{"sgr both past 223",    "\e[<0;1000;999M", {kind = .Press, button = .Left, x = 999, y = 998}},
	// The origin. (1,1) on the wire is (0,0) in the Msg.
	{"sgr origin", "\e[<0;1;1M", {kind = .Press, button = .Left, x = 0, y = 0}},

	// -- Legacy / X10: CSI M Cb+32 Cx+32 Cy+32 ---------------------------
	//
	// ' ' == 32 == Cb 0, '*' == 42 == column 10, '%' == 37 == row 5, so these
	// are the same events as the SGR rows above and must decode identically.
	{"x10 press left",   "\e[M *%", {kind = .Press, button = .Left,   x = 9, y = 4}},
	{"x10 press middle", "\e[M!*%", {kind = .Press, button = .Middle, x = 9, y = 4}},
	{"x10 press right",  "\e[M\"*%", {kind = .Press, button = .Right, x = 9, y = 4}},
	// THE DOCUMENTED ASYMMETRY. Cb bits 0-1 == 3 ('#') is the ONLY thing this
	// encoding can say about a release: the button identity is simply not on
	// the wire, so it reports .None rather than guessing. See x10_mouse.
	{"x10 release loses the button", "\e[M#*%", {kind = .Release, button = .None, x = 9, y = 4}},
	{"x10 drag left",    "\e[M@*%", {kind = .Motion, button = .Left, x = 9, y = 4}},   // '@' == 64 == 32+32
	{"x10 wheel up",     "\e[M`*%", {kind = .Wheel, button = .Wheel_Up,   x = 9, y = 4}},  // '`' == 96 == 32+64
	{"x10 wheel down",   "\e[Ma*%", {kind = .Wheel, button = .Wheel_Down, x = 9, y = 4}},
	{"x10 ctrl+left",    "\e[M0*%", {kind = .Press, button = .Left, x = 9, y = 4, mods = {.Ctrl}}},  // '0' == 48 == 32+16
	{"x10 shift+left",   "\e[M$*%", {kind = .Press, button = .Left, x = 9, y = 4, mods = {.Shift}}}, // '$' == 36 == 32+4
	// THE PAYLOAD TRAP, decoded rather than merely held back. 'M' (77) is
	// column 45 and '~' (126) is row 94: both are ordinary coordinates here,
	// and the fact that they are also CSI final bytes is irrelevant because the
	// scanner never sees them.
	{"x10 with 'M' and '~' in the payload", "\e[M M~", {kind = .Press, button = .Left, x = 44, y = 93}},
	// 0x1B in the payload. It is below the +32 floor, so the coordinate itself
	// is unrecoverable (a wrapped or out-of-spec value) and clamps to 0 -- but
	// the POINT of the row is that it is consumed as a coordinate byte and NOT
	// treated as an escape introducer.
	{"x10 with 0x1B in the payload", "\e[M *\e", {kind = .Press, button = .Left, x = 9, y = 0}},
	// The origin: 33 ('!') is coordinate 1, which is cell 0.
	{"x10 origin", "\e[M !!", {kind = .Press, button = .Left, x = 0, y = 0}},
}

@(test)
test_mouse_decode_table :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	st := Input_State{}; defer delete(st.markers)
	for c in mouse_cases {
		clear(&out); clear(&st.markers); st.in_paste = false
		n := decode_keys(transmute([]u8)c.seq, &out, {}, nil, &st)
		testing.expectf(t, n == len(c.seq), "%s: consumed %d, want %d", c.name, n, len(c.seq))
		testing.expectf(t, len(out) == 0, "%s: emitted %d keys, want 0 (%v)", c.name, len(out), out[:])
		if !testing.expectf(t, len(st.markers) == 1, "%s: %d markers, want 1 (%v)",
			c.name, len(st.markers), st.markers[:]) { continue }
		testing.expectf(t, st.markers[0].kind == .Mouse, "%s: marker kind %v, want .Mouse",
			c.name, st.markers[0].kind)
		testing.expectf(t, st.markers[0].mouse == c.want, "%s: got %v, want %v",
			c.name, st.markers[0].mouse, c.want)
		testing.expectf(t, st.markers[0].at == 0, "%s: marker at %d, want 0", c.name, st.markers[0].at)
	}
}

// `CSI I` in, `CSI O` out. Two zero-sized Msg types rather than one carrying a
// bool -- see Focus_Msg's own comment for why, and for which of the two shapes
// already in this codebase it follows.
@(test)
test_focus_events :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	st := Input_State{}; defer delete(st.markers)

	Case :: struct { seq: string, want: Input_Marker_Kind }
	for c in ([?]Case{{"\e[I", .Focus}, {"\e[O", .Blur}}) {
		clear(&out); clear(&st.markers)
		n := decode_keys(transmute([]u8)c.seq, &out, {}, nil, &st)
		testing.expectf(t, n == 3, "%q: consumed %d, want 3", c.seq, n)
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0", c.seq, len(out))
		if !testing.expectf(t, len(st.markers) == 1, "%q: %d markers, want 1", c.seq, len(st.markers)) {
			continue
		}
		testing.expectf(t, st.markers[0] == Input_Marker{at = 0, kind = c.want},
			"%q: got %v, want kind %v at 0", c.seq, st.markers[0], c.want)
	}

	// `CSI O` is NOT `ESC O`. The SS3 introducer has no '[' and still resolves
	// as the documented Alt+O; a decoder that confused the two would silently
	// turn every Alt+O into a focus-out.
	clear(&out); clear(&st.markers)
	n := decode_keys(transmute([]u8)string("\eO"), &out, {}, nil, &st)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(st.markers), 0)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = 'O', mods = {.Alt}})
}

// THE LEGACY PAYLOAD IS THREE BYTES THAT ARE NOT CSI GRAMMAR, and the whole
// report has to arrive before ANY of it is decoded. key_cases already splits
// these at every boundary within a single call; this test does the other half
// -- feeding them through TWO calls the way the reader loops actually do
// (append to `pending`, decode, drop what was consumed) -- because the trap is
// specifically a report straddling a read boundary.
//
// The payload bytes chosen are the ones that would do damage if they ever
// reached the scanner: 0x1B (would open a phantom escape sequence and swallow
// the next real keystroke), 'M' (would look like an X10 introducer of its own,
// recursively), '~' (a CSI final byte), '[' (the CSI introducer), and 0x00.
@(test)
test_legacy_mouse_holds_back_across_reads :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pending: [dynamic]u8; defer delete(pending)
	st := Input_State{}; defer delete(st.markers)

	Case :: struct { name, seq: string, want: Mouse_Msg }
	cases := [?]Case{
		{"plain",        "\e[M *%",           {kind = .Press, button = .Left, x = 9, y = 4}},
		{"ESC as Cy",    "\e[M *\e",          {kind = .Press, button = .Left, x = 9, y = 0}},
		{"ESC as Cx",    "\e[M \e%",          {kind = .Press, button = .Left, x = 0, y = 4}},
		{"M as Cx, ~ as Cy", "\e[M M~",       {kind = .Press, button = .Left, x = 44, y = 93}},
		{"'[' as Cx",    "\e[M [%",           {kind = .Press, button = .Left, x = 58, y = 4}},
		{"NUL as Cy",    "\e[M *\x00",        {kind = .Press, button = .Left, x = 9, y = 0}},
	}

	checked := 0
	for c in cases {
		b := transmute([]u8)c.seq
		for k in 1 ..< len(b) {
			clear(&out); clear(&pending); clear(&st.markers); st.in_paste = false

			// First chunk. k == 1 is the documented lone-ESC ambiguity (a bare
			// "\e" with nothing after it resolves as Escape); every other prefix
			// must hold back COMPLETELY -- consume nothing, emit nothing, record
			// no marker. Asserted positively rather than skipped so the exception
			// stays visible, exactly as test_paste_split_at_every_byte_boundary
			// does it.
			append(&pending, ..b[:k])
			n := decode_keys(pending[:], &out, {}, nil, &st)
			if n > 0 { remove_range(&pending, 0, n) }
			if k == 1 {
				testing.expectf(t, n == 1 && len(out) == 1 && out[0] == Key_Msg{code = .Escape},
					"%s[:1]: got n=%d %v, want the documented lone-ESC resolution", c.name, n, out[:])
			} else {
				checked += 1
				testing.expectf(t, n == 0 && len(out) == 0 && len(st.markers) == 0,
					"%s[:%d]: got n=%d keys=%v markers=%v, want a complete hold-back",
					c.name, k, n, out[:], st.markers[:])
			}

			// Second chunk completes it. From k >= 2 the whole report must now
			// resolve as ONE marker and no keys at all -- if any payload byte
			// had leaked into the scanner it would show up here as a stray key
			// or as leftover `pending` bytes.
			clear(&out)
			append(&pending, ..b[k:])
			n = decode_keys(pending[:], &out, {}, nil, &st)
			if n > 0 { remove_range(&pending, 0, n) }
			if k == 1 { continue }   // the ESC was already consumed; the tail is not a report
			testing.expectf(t, len(pending) == 0, "%s[:%d]: %d bytes left unconsumed",
				c.name, k, len(pending))
			testing.expectf(t, len(out) == 0, "%s[:%d]: emitted %d keys, want 0 (%v) -- a payload byte leaked into the scanner",
				c.name, k, len(out), out[:])
			if !testing.expectf(t, len(st.markers) == 1, "%s[:%d]: %d markers, want 1",
				c.name, k, len(st.markers)) { continue }
			testing.expectf(t, st.markers[0].kind == .Mouse && st.markers[0].mouse == c.want,
				"%s[:%d]: got %v, want a .Mouse marker holding %v",
				c.name, k, st.markers[0], c.want)
		}
	}
	// Anti-vacuity floor: 6 cases x (len-2) real split points == 6 x 4 == 24.
	testing.expectf(t, checked >= 24, "only %d split points exercised -- table shrank?", checked)
}

// A legacy report must not swallow the keys around it, and neither encoding may
// eat a neighbouring sequence. This is the byte-level companion to the ordering
// test below: `at` is only meaningful if consumption is exact.
@(test)
test_mouse_does_not_swallow_neighbouring_keys :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	st := Input_State{}; defer delete(st.markers)

	// A legacy report between two keys, with a payload byte that IS an escape.
	seq := "a\e[M *\eb\e[A"
	n := decode_keys(transmute([]u8)seq, &out, {}, nil, &st)
	testing.expect_value(t, n, len(seq))
	if testing.expect_value(t, len(out), 3) {
		testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = 'a'})
		testing.expect_value(t, out[1], Key_Msg{code = .Rune, r = 'b'})
		testing.expect_value(t, out[2], Key_Msg{code = .Up})
	}
	testing.expect_value(t, len(st.markers), 1)

	// Two SGR reports and a focus event back to back, no keys at all.
	clear(&out); clear(&st.markers)
	seq = "\e[<0;1;1M\e[<0;1;1m\e[I"
	n = decode_keys(transmute([]u8)seq, &out, {}, nil, &st)
	testing.expect_value(t, n, len(seq))
	testing.expect_value(t, len(out), 0)
	if testing.expect_value(t, len(st.markers), 3) {
		testing.expect_value(t, st.markers[0].mouse.kind, Mouse_Kind.Press)
		testing.expect_value(t, st.markers[1].mouse.kind, Mouse_Kind.Release)
		testing.expect_value(t, st.markers[2].kind, Input_Marker_Kind.Focus)
	}
}

// ORDER RELATIVE TO THE KEYS IS THE WHOLE REASON mouse and focus ride the same
// positioned marker list bracketed paste does, rather than a second unordered
// stream like `enh` (see Input_Marker's comment). A user who clicks to place
// the caret and then types expects the click to arrive FIRST, and a single
// 1024-byte read can easily hold both.
//
// The last case is the one a second, separate stream could not have got right:
// a mouse report and a paste start at the SAME `at`, where only decode order
// says which came first.
@(test)
test_markers_keep_their_position_relative_to_keys :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	st := Input_State{}; defer delete(st.markers)

	// click, then "ab": the marker belongs before out[0].
	n := decode_keys(transmute([]u8)string("\e[<0;1;1Mab"), &out, {}, nil, &st)
	testing.expect_value(t, n, 11)
	testing.expect_value(t, len(out), 2)
	if testing.expect_value(t, len(st.markers), 1) {
		testing.expect_value(t, st.markers[0].at, 0)
	}

	// "ab", then click, then "c": the marker belongs before out[2].
	clear(&out); clear(&st.markers)
	n = decode_keys(transmute([]u8)string("ab\e[<0;1;1Mc"), &out, {}, nil, &st)
	testing.expect_value(t, n, 12)
	testing.expect_value(t, len(out), 3)
	if testing.expect_value(t, len(st.markers), 1) {
		testing.expect_value(t, st.markers[0].at, 2)
	}

	// Focus-out at the very end: `at == len(out)` means "after everything".
	clear(&out); clear(&st.markers)
	n = decode_keys(transmute([]u8)string("ab\e[O"), &out, {}, nil, &st)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, len(out), 2)
	if testing.expect_value(t, len(st.markers), 1) {
		testing.expect_value(t, st.markers[0], Input_Marker{at = 2, kind = .Blur})
	}

	// THE TIE. A click and a paste start both belong at `at == 0`; only the
	// order they were appended in records that the click came first on the
	// wire. Two separate positioned streams would have lost this.
	clear(&out); clear(&st.markers); st.in_paste = false
	n = decode_keys(transmute([]u8)string("\e[<0;1;1M\e[200~x\e[201~"), &out, {}, nil, &st)
	testing.expect_value(t, n, 22)
	testing.expect_value(t, len(out), 1)
	if testing.expect_value(t, len(st.markers), 3) {
		testing.expect_value(t, st.markers[0].kind, Input_Marker_Kind.Mouse)
		testing.expect_value(t, st.markers[0].at, 0)
		testing.expect_value(t, st.markers[1], Input_Marker{at = 0, kind = .Paste_Start})
		testing.expect_value(t, st.markers[2], Input_Marker{at = 1, kind = .Paste_End})
	}
}

// INSIDE A PASTE the bytes are TEXT, and that suspension applies to mouse and
// focus exactly as it does to arrow keys: a pasted "\e[<0;1;1M" is nine literal
// runes, not a click. Without this, pasting a terminal capture would fire
// phantom mouse events at the application.
@(test)
test_mouse_and_focus_are_literal_text_inside_a_paste :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	st := Input_State{}; defer delete(st.markers)

	body :: "\e[<0;1;1M\e[I"
	whole :: "\e[200~" + body + "\e[201~"
	n := decode_keys(transmute([]u8)string(whole), &out, {}, nil, &st)
	testing.expect_value(t, n, len(whole))
	if testing.expect_value(t, len(out), len(body)) {
		for r, i in body {
			testing.expect_value(t, out[i], Key_Msg{code = .Rune, r = r, pasted = true})
		}
	}
	// Exactly the two paste markers -- no mouse, no focus.
	if testing.expect_value(t, len(st.markers), 2) {
		testing.expect_value(t, st.markers[0].kind, Input_Marker_Kind.Paste_Start)
		testing.expect_value(t, st.markers[1].kind, Input_Marker_Kind.Paste_End)
	}
}

// `st = nil` (the default, and what most callers in this file pass) is the same
// degradation `enh = nil` gives the enhancement reply: the sequence is still
// consumed WHOLE -- including the legacy encoding's three raw payload bytes,
// which is the part that would otherwise leak as garbage runes -- but there is
// nowhere to record what it meant. Pinned rather than left implicit.
@(test)
test_mouse_without_a_state_is_still_consumed_whole :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{"\e[<0;10;5M", "\e[M *%", "\e[M *\e", "\e[I", "\e[O"}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)", seq, len(out), out[:])
	}

	// ...and the hold-back still applies with st == nil: a legacy report missing
	// its last payload byte must not be resolved.
	clear(&out)
	n := decode_keys(transmute([]u8)string("\e[M *"), &out)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(out), 0)
}

// Malformed SGR reports land on the cleanly-ignored path rather than being
// forced into a plausible-looking click at a position nothing clicked. All of
// these are COMPLETE sequences, so they are always consumed whole; the question
// is only whether a marker comes out.
//
// The ':' rows are the ones that keep csi_params' sub-parameter rejection
// honest from this side: sgr_mouse has its own parser precisely so csi_params
// did not have to be widened, and that parser must reject ':' too.
@(test)
test_malformed_sgr_mouse_is_cleanly_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	st := Input_State{}; defer delete(st.markers)
	for seq in ([?]string{
		"\e[<M",          // no parameters at all
		"\e[<0M",         // one field
		"\e[<0;10M",      // two fields
		"\e[<0;10;5;7M",  // four fields
		"\e[<0;10:5M",    // a ':' sub-parameter
		"\e[<0;;5M",      // an empty middle field
		"\e[<;10;5M",     // an empty first field
		"\e[<0;10;M",     // an empty last field
		"\e[<<0;10;5M",   // two private prefixes
		"\e[0;10;5M",     // no private prefix at all: not the SGR grammar
		"\e[>0;10;5M",    // the wrong private prefix
		"\e[<0;10;5$M",   // an intermediate byte
	}) {
		clear(&out); clear(&st.markers)
		n := decode_keys(transmute([]u8)seq, &out, {}, nil, &st)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)", seq, len(out), out[:])
		testing.expectf(t, len(st.markers) == 0, "%q: emitted %d markers, want 0 (%v)",
			seq, len(st.markers), st.markers[:])
	}
}

// Mouse_Msg, Focus_Msg and Blur_Msg cross the mailbox like every other Msg, so
// they are subject to box()'s MESSAGE OWNERSHIP CONTRACT (arena.odin). Mouse_Msg
// is the first Msg in this file with a non-trivial payload since Key_Msg, so it
// is worth checking rather than assuming: two enums, two ints and a bit_set,
// nothing owned.
@(test)
test_mouse_and_focus_msgs_are_pod :: proc(t: ^testing.T) {
	testing.expect(t, is_pod_type(Mouse_Msg), "Mouse_Msg must be POD")
	testing.expect(t, is_pod_type(Focus_Msg), "Focus_Msg must be POD")
	testing.expect(t, is_pod_type(Blur_Msg), "Blur_Msg must be POD")
	testing.expect(t, is_pod_type(Input_Marker), "Input_Marker must be POD (it embeds a Mouse_Msg)")
	testing.expect_value(t, size_of(Focus_Msg), 0)
	testing.expect_value(t, size_of(Blur_Msg), 0)
	// Mouse_Button.None must stay the zero value: a motion event with no button
	// held and every legacy release report it, and both build a Mouse_Msg that
	// never names `button`.
	testing.expect_value(t, Mouse_Button{}, Mouse_Button.None)
	testing.expect_value(t, Mouse_Kind{}, Mouse_Kind.Press)
	testing.expect_value(t, Mouse_Msg{}.button, Mouse_Button.None)
}

// ---------------------------------------------------------------------------
// Shift+Tab (CBT).
// ---------------------------------------------------------------------------
//
// `kcbt=\E[Z` is present in 21 of the 40 terminfo entries installed on this
// machine -- xterm, xterm-256color, tmux, tmux-256color, screen and all its
// variants, rxvt, rxvt-unicode -- and "previous field" is a standard binding in
// every form-shaped TUI. It used to fall through to the cleanly-ignored path,
// so Shift+Tab simply did nothing on every one of those terminals unless the
// Kitty protocol was negotiated.
@(test)
test_shift_tab_decodes_from_csi_z :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e[Z"), &out)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Tab, mods = {.Shift}})
}

// THE SHIFT IS IN THE FINAL BYTE, so an explicit modifier parameter must be
// UNIONED with it, not allowed to replace it -- otherwise Ctrl+Shift+Tab would
// arrive as a plain Ctrl+Tab and a UI would run the wrong binding.
@(test)
test_shift_tab_keeps_its_shift_when_another_modifier_is_present :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	// CSI 1;5Z -- xterm_mods(5) is {.Ctrl}; the Shift comes from the 'Z'.
	decode_keys(transmute([]u8)string("\e[1;5Z"), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Tab, mods = {.Ctrl, .Shift}})

	// CSI 1;6Z -- xterm_mods(6) is {.Shift, .Ctrl} already. The union must be
	// idempotent, not additive.
	clear(&out)
	decode_keys(transmute([]u8)string("\e[1;6Z"), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Tab, mods = {.Ctrl, .Shift}})
}

// The two encodings must agree, or the same physical keypress means two
// different things depending on whether the Kitty push happened to be honoured
// -- which is exactly the bug this fixes, in the direction nobody would notice.
@(test)
test_shift_tab_agrees_between_the_legacy_and_kitty_encodings :: proc(t: ^testing.T) {
	legacy := make([dynamic]Key_Msg); defer delete(legacy)
	kitty  := make([dynamic]Key_Msg); defer delete(kitty)
	decode_keys(transmute([]u8)string("\e[Z"),    &legacy)
	decode_keys(transmute([]u8)string("\e[9;2u"), &kitty)
	testing.expect_value(t, len(legacy), 1)
	testing.expect_value(t, len(kitty), 1)
	testing.expect_value(t, legacy[0], kitty[0])
}

// Adding a final byte to csi_letter_code must not have widened anything else:
// 'Z' is the ONLY entry whose modifier comes from the final byte, and every
// other letter key must still arrive with exactly the modifiers its parameter
// named.
@(test)
test_only_csi_z_carries_an_implied_modifier :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq, i in ([?]string{"\e[A", "\e[B", "\e[C", "\e[D", "\e[F", "\e[H", "\e[P", "\e[Q", "\e[R", "\e[S"}) {
		clear(&out)
		decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, len(out) == 1, "%q decoded to %d keys", seq, len(out))
		testing.expectf(t, out[0].mods == {}, "%q must carry no implied modifier, got %v", seq, out[0].mods)
		_ = i
	}
}

// ---------------------------------------------------------------------------
// THE "NOTHING LEAKS AS A KEYSTROKE" CONTRACT.
//
// decode_keys' standing promise is that a sequence it does not understand is
// consumed WHOLE and emits nothing. The tests below cover the five populations
// where that promise used to be false, each of which turned bytes the terminal
// sent into keypresses the application acted on.
// ---------------------------------------------------------------------------

// ESC + C0 == Alt + that KEY.
//
// The Alt branch used to be reached for ANY byte after ESC and never consulted
// decode_c0, contradicting its own "ESC followed by a printable byte" comment.
// The keys below are the ones a user actually presses: every one of them used
// to arrive as a raw control RUNE with the Alt bit and, for Ctrl+Alt+<letter>,
// with no Ctrl bit at all -- so `k.mods == {.Ctrl, .Alt}` matched nothing, and
// an editor with an unfiltered `case .Rune` inserted the control byte into the
// document.
@(test)
test_esc_plus_c0_decodes_through_the_c0_policy :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	Case :: struct { seq: string, want: Key_Msg }
	for c in ([?]Case{
		{"\e\r",   {code = .Enter,     mods = {.Alt}}},              // Alt+Enter, NOT Rune '\r'
		{"\e\x7f", {code = .Backspace, mods = {.Alt}}},              // Alt+Backspace, NOT Rune U+007F
		{"\e\t",   {code = .Tab,       mods = {.Alt}}},              // Alt+Tab, NOT Rune '\t'
		{"\e ",    {code = .Space, r = ' ', mods = {.Alt}}},         // Alt+Space
		{"\e\x01", {code = .Rune, r = 'a', mods = {.Ctrl, .Alt}}},   // Ctrl+Alt+A keeps BOTH bits
		{"\e\x1c", {code = .Rune, r = '\\', mods = {.Ctrl, .Alt}}},  // the 0x1C-0x1F punctuation band
		{"\e\x00", {code = .Space, mods = {.Ctrl, .Alt}}},           // Ctrl+Alt+Space
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)c.seq, &out)
		testing.expectf(t, n == len(c.seq), "%q: consumed %d, want %d", c.seq, n, len(c.seq))
		if !testing.expectf(t, len(out) == 1, "%q: emitted %d keys, want 1 (%v)", c.seq, len(out), out[:]) {
			continue
		}
		testing.expectf(t, out[0] == c.want, "%q: got %v, want %v", c.seq, out[0], c.want)
	}

	// Alt+<printable> is untouched, and so is the double-Escape resolution --
	// 0x1b is <= 0x20 and would land in the new C0 gate if the double-Escape arm
	// above it ever stopped claiming it first.
	clear(&out)
	n := decode_keys(transmute([]u8)string("\ea\e\e"), &out)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = 'a', mods = {.Alt}})
	testing.expect_value(t, out[1], Key_Msg{code = .Escape})
	testing.expect_value(t, out[2], Key_Msg{code = .Escape})
}

// The C0 policy really is ONE policy: the legacy flags reach the Alt path too,
// so Alt+Enter with .Ctrl_M set is Ctrl+Alt+m rather than Alt+Enter. What must
// NOT change is Ctrl_Open_Bracket, because ESC-after-ESC is claimed by the
// double-Escape arm before the C0 gate can see it.
@(test)
test_alt_c0_honours_the_legacy_flags :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	decode_keys(transmute([]u8)string("\e\r"), &out, {.Ctrl_M})
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = 'm', mods = {.Ctrl, .Alt}})

	clear(&out)
	decode_keys(transmute([]u8)string("\e\x7f"), &out, {.Backspace})
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Delete, mods = {.Alt}})

	// With Ctrl_Open_Bracket set, "\e\e" is still TWO ctrl+[ keypresses -- the
	// double-Escape arm, not an Alt+ctrl+[.
	clear(&out)
	decode_keys(transmute([]u8)string("\e\e"), &out, {.Ctrl_Open_Bracket})
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = '[', mods = {.Ctrl}})
	testing.expect_value(t, out[1], Key_Msg{code = .Rune, r = '[', mods = {.Ctrl}})
}

// STRING ESCAPES (OSC, DCS, APC, PM, SOS) must be consumed whole and emit
// NOTHING.
//
// These are the bytes a terminal sends unbidden -- an OSC 11 background-colour
// reply left in flight by the shell, an OSC 52 clipboard read, an XTVERSION
// DCS, a Kitty graphics APC ack. With no arm for them the introducer became
// Alt+']' / Alt+'P' / Alt+'_', every payload byte became a Key_Msg, a BEL
// terminator became Ctrl+G and an ST terminator became Alt+'\'. The OSC 11
// reply below produced 23 keypresses before this arm existed; the assertion is
// zero.
@(test)
test_string_escapes_are_consumed_whole :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{
		"\e]11;rgb:2e2e/3434/3a3a\e\\",         // OSC 11 background colour, ST-terminated
		"\e]11;rgb:2e2e/3434/3a3a\a",           // the same reply, BEL-terminated
		"\e]52;c;aGVsbG8gd29ybGQ=\a",           // OSC 52 clipboard read
		"\e]0;a window title\a",                // OSC 0
		"\eP>|xterm(390)\e\\",                  // XTVERSION DCS reply
		"\eP1$r0m\e\\",                         // DECRQSS reply
		"\eP1;2|\a payload\e\\",               // BEL does NOT terminate a DCS: ST does
		"\e_Gi=1;\a\e\\",                      // nor an APC
		"\e_Gi=31;OK\e\\",                      // Kitty graphics APC ack
		"\e^some private message\e\\",          // PM
		"\eXa start-of-string\e\\",             // SOS
		"\e]11;rgb:0/0/0\x9c",                  // 8-bit ST terminator
		"\e]11;\x18",                           // CAN cancels the string
		"\e]11;\x1a",                           // SUB cancels it too
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)", seq, len(out), out[:])
	}
}

// The hold-back contract on the new arm: every proper prefix of a string escape
// must consume nothing and emit nothing, so a reply split across two read()s
// cannot half-decode. The lone-ESC exception at k == 1 is the same documented
// ambiguity every other sequence has.
@(test)
test_string_escape_holds_back_until_its_terminator :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{"\e]11;rgb:00/00/00\e\\", "\eP>|xterm\a\e\\", "\e_Gi=1;OK\e\\"}) {
		b := transmute([]u8)seq
		for k in 2 ..< len(b) {
			clear(&out)
			n := decode_keys(b[:k], &out)
			testing.expectf(t, n == 0 && len(out) == 0,
				"%q[:%d]: got n=%d %v, want a complete hold-back", seq, k, n, out[:])
		}
	}

	// And a real keypress after a complete reply still decodes, in the same
	// buffer -- the whole point of consuming the reply rather than resyncing
	// somewhere inside it.
	clear(&out)
	n := decode_keys(transmute([]u8)string("\e]11;rgb:0/0/0\a\e[A"), &out)
	testing.expect_value(t, n, 18)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})
}

// An ESC inside a string that is NOT followed by '\' aborts the string and is
// handed back to the main loop, so a real sequence arriving after a malformed
// reply still decodes instead of being swallowed as payload.
@(test)
test_an_esc_inside_a_string_escape_aborts_it :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e]11;rgb\e[A"), &out)
	testing.expect_value(t, n, 11)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})
}

// Inside a bracketed paste a string introducer is TEXT, like everything else --
// the paste branch runs before the introducer gate, and pasting a file that
// happens to contain "\e]0;" must not put the decoder into an OSC.
@(test)
test_string_escapes_are_literal_text_inside_a_paste :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	pst := Input_State{}; defer delete(pst.markers)
	seq := "\e[200~\e]0;x\a\e[201~"
	n := decode_keys(transmute([]u8)seq, &out, {}, nil, &pst)
	testing.expect_value(t, n, len(seq))
	testing.expect(t, !pst.in_paste, "the paste must have ended")
	// ESC ] 0 ; x BEL -- six literal runes, all flagged pasted.
	testing.expect_value(t, len(out), 6)
	for k in out {
		testing.expect(t, k.pasted, "pasted content must be flagged")
		testing.expect_value(t, k.code, Key_Code.Rune)
	}
}

// urxvt's '$'-final modified keys. '$' is 0x24, an ECMA-48 INTERMEDIATE byte,
// so the old scan treated "\e[3$" as incomplete and took the NEXT byte as the
// sequence's final -- destroying the following keystroke when it was printable,
// and injecting the parameter run as literal runes when it was not.
@(test)
test_urxvt_dollar_keys_do_not_eat_the_next_keystroke :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)

	// (a) The keystroke after a '$' key is a letter -- it used to be consumed as
	//     the sequence's final byte and lost outright.
	n := decode_keys(transmute([]u8)string("\e[3$X"), &out)
	testing.expect_value(t, n, 5)
	if testing.expect_value(t, len(out), 2) {
		testing.expect_value(t, out[0], Key_Msg{code = .Delete, mods = {.Shift}})
		testing.expect_value(t, out[1], Key_Msg{code = .Rune, r = 'X'})
	}

	// (b) The keystroke after it is an arrow -- ESC is not a valid final, so the
	//     old resynchronisation arm dropped "\e[" and typed '3' and '$'.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\e[3$\e[A"), &out)
	testing.expect_value(t, n, 7)
	if testing.expect_value(t, len(out), 2) {
		testing.expect_value(t, out[0], Key_Msg{code = .Delete, mods = {.Shift}})
		testing.expect_value(t, out[1], Key_Msg{code = .Up})
	}
}

// The full urxvt modified-tilde table, in all three final bytes. rxvt-unicode
// is one of the two terminals the xterm defaults measurably do not cover, and
// these twelve keys are the larger half of that miss.
@(test)
test_urxvt_modified_tilde_keys_decode :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	Case :: struct { seq: string, want: Key_Msg }
	for c in ([?]Case{
		{"\e[2$", {code = .Insert,    mods = {.Shift}}},          // kIC
		{"\e[3$", {code = .Delete,    mods = {.Shift}}},          // kDC
		{"\e[5$", {code = .Page_Up,   mods = {.Shift}}},          // kPRV
		{"\e[6$", {code = .Page_Down, mods = {.Shift}}},          // kNXT
		{"\e[7$", {code = .Home,      mods = {.Shift}}},          // kHOM
		{"\e[8$", {code = .End,       mods = {.Shift}}},          // kEND
		{"\e[3^", {code = .Delete,    mods = {.Ctrl}}},
		{"\e[7^", {code = .Home,      mods = {.Ctrl}}},
		{"\e[3@", {code = .Delete,    mods = {.Ctrl, .Shift}}},
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)c.seq, &out)
		testing.expectf(t, n == len(c.seq), "%q: consumed %d, want %d", c.seq, n, len(c.seq))
		if !testing.expectf(t, len(out) == 1, "%q: emitted %d keys, want 1 (%v)", c.seq, len(out), out[:]) {
			continue
		}
		testing.expectf(t, out[0] == c.want, "%q: got %v, want %v", c.seq, out[0], c.want)
	}
}

// THE GUARD ON THE '$' ARM. A DECRQM reply's '$' is a genuine intermediate byte
// followed by the final 'y'; terminating the sequence at the '$' would leave the
// 'y' in the stream as a rune, which is the same leak on a different sequence.
// "\e[?2004;1$y" is already in test_decode_unsupported_csi_is_cleanly_ignored's
// corpus; this pins WHY it still passes.
@(test)
test_the_dollar_arm_does_not_steal_decrpm :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq in ([?]string{"\e[?2004;1$y", "\e[?1;2$y", "\e[$y"}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)", seq, len(out), out[:])
	}
}

// A CSI whose intermediate run is followed by a byte that cannot be a final is
// consumed THROUGH the intermediates rather than resynchronised two bytes in.
// The old arm dropped only "\e[" and left the parameter and intermediate bytes
// -- all printable ASCII -- to be typed into the application.
@(test)
test_a_csi_ending_on_an_intermediate_is_consumed_not_leaked :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	// "\e[1 " (an intermediate SP) followed by Ctrl+C: the C0 byte cannot be a
	// final, so the sequence ends at the SP and Ctrl+C decodes on its own.
	n := decode_keys(transmute([]u8)string("\e[1 \x03"), &out)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Rune, r = 'c', mods = {.Ctrl}})
}

// THE LINUX VIRTUAL CONSOLE'S F1-F5: "\e[[A" .. "\e[[E". '[' is a legal CSI
// final byte, so the old scan consumed "\e[[" as an unknown three-byte sequence
// and left the letter behind -- pressing F1 on a bare TTY typed a capital 'A'
// into the application.
@(test)
test_linux_console_function_keys_decode :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for seq, k in ([?]string{"\e[[A", "\e[[B", "\e[[C", "\e[[D", "\e[[E"}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == 4, "%q: consumed %d, want 4", seq, n)
		if !testing.expectf(t, len(out) == 1, "%q: emitted %d keys, want 1 (%v)", seq, len(out), out[:]) {
			continue
		}
		testing.expectf(t, out[0] == Key_Msg{code = Key_Code(int(Key_Code.F1) + k)},
			"%q: got %v, want F%d", seq, out[0], k + 1)
	}

	// A letter outside A-E is consumed whole and emits nothing -- never leaked.
	clear(&out)
	n := decode_keys(transmute([]u8)string("\e[[Z"), &out)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, len(out), 0)

	// And the three-byte prefix holds back for its letter instead of resolving.
	clear(&out)
	n = decode_keys(transmute([]u8)string("\e[["), &out)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(out), 0)
}

// 8-BIT C1 INTRODUCERS. 0x9B is CSI, 0x8F is SS3, 0x90 is DCS, 0x9D is OSC.
// These used to fall through to the UTF-8 path, where utf8_lead_len reports 1
// for the whole 0x80-0xBF band and decode_rune substitutes U+FFFD -- so an
// 8-bit Up arrow came out as a replacement rune plus a literal 'A', and an
// 8-bit OSC leaked its entire payload.
@(test)
test_eight_bit_c1_introducers_decode :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)

	clear(&out)
	n := decode_keys([]u8{0x9b, 'A'}, &out)                 // CSI A == Up
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Up})

	clear(&out)
	n = decode_keys([]u8{0x9b, '1', ';', '5', 'C'}, &out)   // CSI 1;5C == Ctrl+Right
	testing.expect_value(t, n, 5)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .Right, mods = {.Ctrl}})

	clear(&out)
	n = decode_keys([]u8{0x8f, 'P'}, &out)                  // SS3 P == F1
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Key_Msg{code = .F1})

	// 8-bit DCS and OSC, consumed whole and emitting nothing.
	clear(&out)
	n = decode_keys([]u8{0x90, '>', '|', 'x', 0x9c}, &out)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, len(out), 0)

	clear(&out)
	n = decode_keys([]u8{0x9d, '1', '1', ';', 'x', 0x07}, &out)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 0)
}

// The 8-bit introducers hold back exactly like their 7-bit spellings. 0x8F is
// the one that differs from ESC O: a lone ESC O is a plausible Alt+O keypress
// and resolves, whereas a lone 0x8F can only be SS3, so it waits.
@(test)
test_eight_bit_introducers_hold_back :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	for b in ([?][]u8{{0x9b}, {0x9b, '1'}, {0x9b, '1', ';'}, {0x8f}, {0x90, 'x'}, {0x9d, 'x'}}) {
		clear(&out)
		n := decode_keys(b, &out)
		testing.expectf(t, n == 0 && len(out) == 0,
			"%v: got n=%d %v, want a complete hold-back", b, n, out[:])
	}
}

// A C1 byte that introduces nothing is xterm's eightBitInput meta encoding:
// with that resource on and UTF-8 off, Alt+Ctrl+A arrives as 0x81 rather than
// as "ESC 0x01". Routed through decode_c0 so the two spellings produce the
// IDENTICAL Key_Msg -- a decoder that answered "what is Ctrl+Alt+A" twice would
// be indefensible.
@(test)
test_plain_c1_bytes_decode_as_alt_plus_their_c0 :: proc(t: ^testing.T) {
	seven := make([dynamic]Key_Msg); defer delete(seven)
	eight := make([dynamic]Key_Msg); defer delete(eight)
	for b in u8(0x80) ..= u8(0x9f) {
		// The six introducers have their own grammars and are covered above.
		switch b {
		case 0x8f, 0x90, 0x98, 0x9b, 0x9d, 0x9e, 0x9f: continue
		}
		clear(&seven); clear(&eight)
		decode_keys([]u8{0x1b, b - 0x80}, &seven)
		n := decode_keys([]u8{b}, &eight)
		testing.expectf(t, n == 1, "%02x: consumed %d, want 1", b, n)
		if !testing.expectf(t, len(eight) == 1 && len(seven) == 1,
			"%02x: emitted %d/%d keys, want 1/1", b, len(seven), len(eight)) { continue }
		testing.expectf(t, eight[0] == seven[0],
			"%02x: 8-bit gave %v, 7-bit gave %v -- they must agree", b, eight[0], seven[0])
	}
	// Spot-check the actual value, not just the agreement.
	clear(&eight)
	decode_keys([]u8{0x81}, &eight)
	testing.expect_value(t, len(eight), 1)
	testing.expect_value(t, eight[0], Key_Msg{code = .Rune, r = 'a', mods = {.Ctrl, .Alt}})

	// 0xA0-0xBF stays what utf8_lead_len says it is: a stray continuation byte,
	// U+FFFD. The C1 band is 0x80-0x9F and must not have widened.
	clear(&eight)
	decode_keys([]u8{0xa0}, &eight)
	testing.expect_value(t, len(eight), 1)
	testing.expect_value(t, eight[0].code, Key_Code.Rune)
	testing.expect_value(t, eight[0].r, rune(0xfffd))
}

// XTERM'S modifyOtherKeys REPORT: CSI 27 ; <mod> ; <codepoint> ~. Rejected twice
// over before -- by csi_decode's `count > 2` gate, and by csi_tilde_code, whose
// table lists 27 as unassigned. It is the only legacy mechanism besides the
// Kitty protocol that resolves the Ctrl+I/Tab and Ctrl+M/Enter collisions or
// delivers Ctrl+digit at all.
@(test)
test_modify_other_keys_reports_decode :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	Case :: struct { seq: string, want: Key_Msg }
	for c in ([?]Case{
		{"\e[27;5;9~",   {code = .Tab,   mods = {.Ctrl}}},              // Ctrl+Tab, NOT Tab
		{"\e[27;5;13~",  {code = .Enter, mods = {.Ctrl}}},              // Ctrl+Enter, NOT Enter
		{"\e[27;5;49~",  {code = .Rune, r = '1', mods = {.Ctrl}}},      // Ctrl+1
		{"\e[27;6;46~",  {code = .Rune, r = '.', mods = {.Ctrl, .Shift}}},
		{"\e[27;2;65~",  {code = .Rune, r = 'A', mods = {.Shift}}},
	}) {
		clear(&out)
		n := decode_keys(transmute([]u8)c.seq, &out)
		testing.expectf(t, n == len(c.seq), "%q: consumed %d, want %d", c.seq, n, len(c.seq))
		if !testing.expectf(t, len(out) == 1, "%q: emitted %d keys, want 1 (%v)", c.seq, len(out), out[:]) {
			continue
		}
		testing.expectf(t, out[0] == c.want, "%q: got %v, want %v", c.seq, out[0], c.want)
	}

	// It agrees with the Kitty spelling of the same keypress, for the same
	// reason Shift+Tab has to: one physical key must not mean two things
	// depending on which protocol the terminal happened to negotiate.
	kitty := make([dynamic]Key_Msg); defer delete(kitty)
	clear(&out)
	decode_keys(transmute([]u8)string("\e[27;5;9~"), &out)
	decode_keys(transmute([]u8)string("\e[9;5u"),    &kitty)
	if testing.expect_value(t, len(out), 1) && testing.expect_value(t, len(kitty), 1) {
		testing.expect_value(t, out[0], kitty[0])
	}

	// 27 is still not a tilde KEY id: the two-parameter forms stay ignored, and
	// a three-parameter form whose codepoint has no Key_Code is ignored too.
	for seq in ([?]string{"\e[27~", "\e[27;5~", "\e[27;5;57400~"}) {
		clear(&out)
		n := decode_keys(transmute([]u8)seq, &out)
		testing.expectf(t, n == len(seq), "%q: consumed %d, want %d", seq, n, len(seq))
		testing.expectf(t, len(out) == 0, "%q: emitted %d keys, want 0 (%v)", seq, len(out), out[:])
	}
}
