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
