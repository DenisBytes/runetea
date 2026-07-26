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

// PageUp, as xterm encodes it: ESC [ 5 ~. A parameterised CSI this decoder
// assigns no meaning to must consume the whole sequence and emit nothing --
// not leak the trailing '~' as a spurious rune keypress.
@(test)
test_decode_unsupported_csi_is_cleanly_ignored :: proc(t: ^testing.T) {
	out := make([dynamic]Key_Msg); defer delete(out)
	n := decode_keys(transmute([]u8)string("\e[5~"), &out)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, len(out), 0)
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

	// Once the rest of the sequence arrives, it resolves as one unsupported
	// (cleanly ignored) CSI -- not three garbage runes ';', '5', 'C'.
	n = decode_keys(transmute([]u8)string("\e[1;5C"), &out)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(out), 0)
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
