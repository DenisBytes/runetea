package runetea

import "core:unicode/utf8"

Key_Kind :: enum u8 { Press, Release }

// Collapsed vocabulary: Bubble Tea matches six key/mouse types by method set,
// which Odin cannot express. One struct with a discriminant instead (spec §9).
Key_Code :: enum u8 {
	Rune, Enter, Escape, Backspace, Tab, Space,
	Up, Down, Right, Left,
}

Modifier  :: enum u8 { Ctrl, Alt, Shift }
Modifiers :: bit_set[Modifier; u8]

Key_Msg :: struct {
	kind: Key_Kind,
	code: Key_Code,
	r:    rune,
	mods: Modifiers,
}

// Decodes as many complete keys as `data` contains, appending to `out`.
// Returns the number of bytes consumed; a trailing partial escape sequence is
// left unconsumed so the caller can retry once more bytes arrive.
//
// This is a minimal decoder: printable runes, C0 control bytes as
// Ctrl+letter, Enter/Tab/Backspace/Escape, and the four arrow keys -- just
// enough for the spike's two examples. It does not parse CSI parameters,
// SS3 sequences, or the Kitty protocol; that is T1/T4 work (spec §12).
//
// HOLD-BACK CONTRACT (the subtle part): a sequence that is still arriving --
// "\e" alone at the very end of the buffer, or "\e[" with nothing after it --
// must NOT be decoded yet. Emitting a spurious Escape for either would be the
// classic bug where a CSI sequence split across two reads (e.g. one read
// stops right after the '[') turns into a bogus Escape keypress plus garbage
// once the rest of the sequence arrives and gets decoded on its own. These
// two "not enough bytes yet" cases return early with `consumed` short of
// `len(data)`, and Task 10's reader loop retries the undecoded tail once more
// bytes land.
//
// The ONE exception is a lone ESC at the very end of the buffer with no
// sequence pending (data == {0x1b}, nothing else on the stream): decoded
// immediately as Key_Code.Escape. This is genuinely ambiguous -- it could be
// a real Escape keypress, or the start of a sequence whose remaining bytes
// haven't arrived yet -- and disambiguating it properly requires a timer
// (has more input arrived within N milliseconds?). This spike does not have
// one, so it resolves the ambiguity as Escape. That is a documented T1
// limitation (spec §12), not a bug, and it is a DIFFERENT case from the
// hold-back ones above: this one has no continuation byte present at all to
// hold back on, whereas "\e[" has a continuation byte (`[`) that positively
// identifies a sequence in progress.
decode_keys :: proc(data: []u8, out: ^[dynamic]Key_Msg) -> (consumed: int) {
	i := 0
	for i < len(data) {
		b := data[i]

		// CSI sequences: ESC [ <final>
		if b == 0x1b {
			if i + 1 >= len(data) {
				// Lone ESC at the very end of the buffer. Ambiguous: it may be a
				// real Escape or the start of a sequence still in flight. The
				// spike resolves it as Escape; a timer-based disambiguation is
				// T1 work (spec §12).
				append(out, Key_Msg{code = .Escape})
				return i + 1
			}
			if data[i + 1] == '[' {
				if i + 2 >= len(data) { return i }   // incomplete: hold back
				code: Key_Code
				switch data[i + 2] {
				case 'A': code = .Up
				case 'B': code = .Down
				case 'C': code = .Right
				case 'D': code = .Left
				case:
					i += 3   // unrecognised CSI: skip it
					continue
				}
				append(out, Key_Msg{code = code})
				i += 3
				continue
			}
			// ESC followed by a printable byte == Alt+key
			r, w := utf8.decode_rune(data[i + 1:])
			append(out, Key_Msg{code = .Rune, r = r, mods = {.Alt}})
			i += 1 + w
			continue
		}

		switch b {
		case '\r', '\n': append(out, Key_Msg{code = .Enter});     i += 1; continue
		case 0x7f:       append(out, Key_Msg{code = .Backspace}); i += 1; continue
		case '\t':       append(out, Key_Msg{code = .Tab});       i += 1; continue
		case ' ':        append(out, Key_Msg{code = .Space, r = ' '}); i += 1; continue
		}

		// C0 control bytes are Ctrl+letter
		if b < 0x20 {
			append(out, Key_Msg{code = .Rune, r = rune(b + 'a' - 1), mods = {.Ctrl}})
			i += 1
			continue
		}

		r, w := utf8.decode_rune(data[i:])
		if w == 0 { return i }   // incomplete UTF-8: hold back
		append(out, Key_Msg{code = .Rune, r = r})
		i += w
	}
	return i
}
