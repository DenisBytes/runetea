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

// Expected length in bytes of the UTF-8 sequence introduced by lead byte `b`,
// per RFC 3629's lead-byte pattern. Used to tell "sequence not fully arrived
// yet" apart from "invalid byte" -- something utf8.decode_rune's width
// cannot do for us, since it always returns width >= 1 (it substitutes
// RUNE_ERROR for a too-short slice instead of reporting incompleteness);
// width == 0 fires only for a genuinely empty slice, which decode_keys'
// loop invariant (i < len(data)) already rules out on every call site.
// A stray continuation byte or an invalid lead byte (0x80-0xBF, 0xF8-0xFF)
// reports length 1 -- it can never become valid no matter how many more
// bytes arrive, so there is nothing to hold back for; decode_rune will emit
// RUNE_ERROR for it and we move on.
utf8_lead_len :: proc(b: u8) -> int {
	switch {
	case b < 0x80:              return 1
	case b >= 0xC0 && b < 0xE0: return 2
	case b >= 0xE0 && b < 0xF0: return 3
	case b >= 0xF0 && b < 0xF8: return 4
	case:                       return 1
	}
}

// Decodes as many complete keys as `data` contains, appending to `out`.
// Returns the number of bytes consumed; a trailing partial escape sequence
// or a trailing partial UTF-8 rune is left unconsumed so the caller can
// retry once more bytes arrive.
//
// This is a minimal decoder: printable runes, C0 control bytes as
// Ctrl+letter, Enter/Tab/Backspace/Escape, and the four arrow keys -- just
// enough for the spike's two examples. It does not decode parameterised CSI
// keys (PageUp, Ctrl+arrow, F-keys, ...), SS3 sequences, or the Kitty
// protocol; those are cleanly ignored (see the CSI handling below), and
// actually decoding what they mean is T1/T4 work (spec §12).
//
// HOLD-BACK CONTRACT (the subtle part): a sequence that is still arriving --
// "\e" alone at the very end of the buffer, "\e[" with nothing after it, a
// CSI whose final byte (0x40-0x7E) hasn't arrived yet, or a UTF-8 lead byte
// without all of its continuation bytes yet -- must NOT be decoded yet.
// Emitting a spurious Escape, or a spurious U+FFFD replacement rune, for any
// of these would be the classic bug where a sequence split across two reads
// turns into a bogus keypress plus garbage once the rest of it arrives and
// gets decoded on its own. Every "not enough bytes yet" case below returns
// early with `consumed` short of `len(data)`, and Task 10's reader loop
// retries the undecoded tail once more bytes land.
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
// hold back on, whereas "\e[", a partial CSI, and a partial UTF-8 rune each
// have at least one byte already in hand that positively identifies a
// sequence in progress.
//
// A second ESC arriving immediately after the first ("\e\e", e.g. a user
// double-tapping Escape in a modal/vim-like UI) is likewise not ambiguous:
// it is treated as a real Escape keypress, and the second ESC byte is left
// for the next loop iteration to resolve on its own terms -- as a lone
// trailing Escape, as the start of a new sequence, or as another double-ESC.
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
				// CSI grammar: ESC [ <parameter bytes 0x30-0x3F>*
				//                    <intermediate bytes 0x20-0x2F>*
				//                    <final byte 0x40-0x7E>
				// Scan to the final byte without interpreting any parameters --
				// that is enough to know where the sequence ENDS, which is all
				// that is needed to either hold it back or skip it cleanly.
				// Deciding what a parameterised sequence MEANS stays T1/T4.
				j := i + 2
				for j < len(data) && data[j] >= 0x30 && data[j] <= 0x3F { j += 1 }
				for j < len(data) && data[j] >= 0x20 && data[j] <= 0x2F { j += 1 }
				if j >= len(data) { return i }   // final byte not arrived yet: hold back
				final := data[j]
				if final < 0x40 || final > 0x7E {
					// Malformed CSI (e.g. a stray C0/high byte where a
					// parameter/intermediate/final byte was expected): not a
					// sequence in flight, nothing to hold back for. Drop just
					// the introducer so we resynchronise instead of getting
					// stuck.
					i += 2
					continue
				}
				seq_len := j - i + 1
				// The four arrows are the only 3-byte CSI (no parameter or
				// intermediate bytes) this decoder assigns a meaning to.
				if seq_len == 3 {
					code: Key_Code
					matched := true
					switch final {
					case 'A': code = .Up
					case 'B': code = .Down
					case 'C': code = .Right
					case 'D': code = .Left
					case:     matched = false
					}
					if matched {
						append(out, Key_Msg{code = code})
						i += seq_len
						continue
					}
				}
				// Unsupported CSI (parameterised, or an unrecognised bare
				// final byte): the whole thing is a single complete sequence
				// now that its final byte has arrived, so consume it as one
				// unit and emit nothing -- "cleanly ignore an unsupported
				// key" rather than leaking its trailing bytes as garbage
				// rune keypresses.
				i += seq_len
				continue
			}
			if data[i + 1] == 0x1b {
				// Double Escape: resolve the first as a real Escape keypress
				// and leave the second ESC byte for the next iteration.
				append(out, Key_Msg{code = .Escape})
				i += 1
				continue
			}
			// ESC followed by a printable byte == Alt+key
			need := utf8_lead_len(data[i + 1])
			if i + 1 + need > len(data) { return i }   // incomplete UTF-8: hold back
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

		need := utf8_lead_len(b)
		if i + need > len(data) { return i }   // incomplete UTF-8: hold back
		r, w := utf8.decode_rune(data[i:])
		append(out, Key_Msg{code = .Rune, r = r})
		i += w
	}
	return i
}
