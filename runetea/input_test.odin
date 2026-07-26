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
