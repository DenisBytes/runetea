package runetea

import "core:unicode/utf8"

Key_Kind :: enum u8 { Press, Release }

// Collapsed vocabulary: Bubble Tea matches six key/mouse types by method set,
// which Odin cannot express. One struct with a discriminant instead (spec §9).
//
// New members are APPENDED, never inserted: nothing serialises a Key_Code, but
// the enum's numeric order is relied on inside this file (F1 + n indexing in
// the CSI/SS3 tables), so keeping the F-key block contiguous and in order is
// load-bearing, and reordering the block would silently mis-decode.
Key_Code :: enum u8 {
	Rune, Enter, Escape, Backspace, Tab, Space,
	Up, Down, Right, Left,
	Home, End, Page_Up, Page_Down, Insert, Delete,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	// VT220 keys that modern keyboards dropped. Only ever produced with the
	// matching Legacy_Key flag set; by default CSI 1~ / CSI 4~ are Home/End.
	// APPENDED, per the rule above -- putting them next to Home/End where they
	// "belong" would shift the F-key block and silently mis-decode every
	// function key.
	Find, Select,
}

// The legacy-encoding collisions, one flag per collision.
//
// Terminals collapse distinct keypresses onto the same byte: Ctrl+I and Tab are
// both 0x09, Ctrl+M and Enter are both 0x0D, Ctrl+[ and Escape are both 0x1B.
// No decoder can separate them from the byte alone -- that is what the Kitty
// keyboard protocol and modifyOtherKeys exist for. What a decoder CAN do is let
// the application say which side of each collision it wants, which is what this
// is: ultraviolet's LegacyKeyEncoding (decoder.go), ported.
//
// THE ZERO VALUE IS THE SANE DEFAULT. Every flag is an opt-OUT of the modern
// reading in favour of the historical one, and `{}` reproduces ultraviolet's
// documented defaults exactly:
//
//   flag              clear (default)              set
//   ----------------- ---------------------------- ----------------------------
//   Ctrl_At           0x00 -> Ctrl+Space           0x00 -> Ctrl+@
//   Ctrl_I            0x09 -> Tab                  0x09 -> Ctrl+i
//   Ctrl_M            0x0D -> Enter                0x0D -> Ctrl+m
//   Ctrl_Open_Bracket 0x1B -> Escape               0x1B -> Ctrl+[
//   Backspace         0x08 Ctrl+h, 0x7F Backspace  0x08 Backspace, 0x7F Delete
//   Find              CSI 1~ -> Home               CSI 1~ -> Find
//   Select            CSI 4~ -> End                CSI 4~ -> Select
//
// Bubble Tea itself does NOT expose these (its whole source has zero references
// to LegacyKeyEncoding); they live only in ultraviolet, the layer below it.
// RuneTea surfacing them on Program is a deliberate, cheap improvement over the
// thing being ported, not an accident of the port.
Legacy_Key :: enum u8 {
	Ctrl_At,            // 0x00 -> ctrl+@ instead of ctrl+space
	Ctrl_I,             // 0x09 -> ctrl+i instead of Tab
	Ctrl_M,             // 0x0D -> ctrl+m instead of Enter
	Ctrl_Open_Bracket,  // 0x1B -> ctrl+[ instead of Escape
	Backspace,          // the Backspace key sends 0x08, not 0x7F
	Find,               // CSI 1~ -> Find instead of Home
	Select,             // CSI 4~ -> Select instead of End
}
Legacy_Key_Encoding :: bit_set[Legacy_Key; u8]

// Meta is the 4th xterm modifier bit (see xterm_mods). It is NOT the same as
// Alt on every terminal -- most Unix terminals send ESC-prefixed bytes for Alt
// and never set this bit -- but the wire encoding has a slot for it, so it
// gets a name rather than being silently folded into Alt.
Modifier  :: enum u8 { Ctrl, Alt, Shift, Meta }
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

// THE C0 NORMALISATION POLICY, in one place on purpose.
//
// Applies to the bytes 0x00-0x20 and 0x7F. Named keys win by default and carry
// no Ctrl flag: Enter, Tab, Space, Escape and Backspace are reported as
// themselves; every other C0 byte becomes Rune + {.Ctrl}. That is ultraviolet's
// default table (key_table.go's buildKeysTable, and parseControl's fallback),
// and it never reports a modifier the user did not press -- an app checking
// `key.mods == {}` on a real Tab keypress is right to expect an empty set.
//
// Where a byte is genuinely ambiguous, `legacy` decides -- see Legacy_Key for
// the full table and for why its zero value is the right default. This proc is
// the ONLY place those decisions are made, which is the whole reason it exists
// as a proc rather than as switch arms inlined in decode_keys; ESC is routed
// back through here (decode_keys resolves an Escape by calling decode_c0(0x1b))
// so Ctrl_Open_Bracket cannot drift out of sync with the rest.
//
// The b + 'a' - 1 fallback is b + 0x60, ultraviolet's own arithmetic for
// SOH..SUB (0x01-0x1A): 0x03 -> 'c', 0x0A -> 'j' (LF is Ctrl+J, NOT Enter --
// only CR is Enter, and term.odin clears ICRNL precisely so Enter still arrives
// as 0x0D), 0x1A -> 'z'.
//
decode_c0 :: proc(b: u8, legacy: Legacy_Key_Encoding) -> Key_Msg {
	switch b {
	// NUL. Both Ctrl+Space and Ctrl+@ produce it -- the ANSI encoding has one
	// byte for two keypresses -- and ultraviolet's default names it Ctrl+Space.
	// (It used to fall through to the arithmetic below, which lands on '`':
	// neither '@' (0x40) nor ' ' (0x20), just wrong.)
	case 0x00:
		if .Ctrl_At in legacy { return Key_Msg{code = .Rune, r = '@', mods = {.Ctrl}} }
		// No `r = ' '`: r carries the TEXT the keypress produces, and Ctrl+Space
		// produces none. Mirrors ultraviolet, where plain SP has Text " " and
		// Ctrl+Space has none.
		return Key_Msg{code = .Space, mods = {.Ctrl}}
	// BS. Which byte the Backspace key sends is a terminfo (kbs) question this
	// decoder does not consult, so it is a flag instead: see Legacy_Key.
	//
	// DELIBERATE DEVIATION FROM ULTRAVIOLET, which is self-contradictory here.
	// Its flagBackspace doc says "the driver will send a BS (0x08) instead of a
	// DEL (0x7F) when the Backspace key is pressed", but BOTH of its code paths
	// (key_table.go's `string(byte(ansi.BS)): {Code: 'h', Mod: ModCtrl}` and
	// decoder.go's parseControl `case ansi.BS`) leave 0x08 as Ctrl+h
	// unconditionally, and only flip 0x7F from Backspace to Delete. With the
	// flag set, ultraviolet can therefore never report Backspace AT ALL -- the
	// two code paths agree with each other and both contradict the flag's stated
	// purpose. RuneTea implements the coherent reading: with the flag set, 0x08
	// IS the Backspace key and 0x7F is Delete.
	case 0x08:
		if .Backspace in legacy { return Key_Msg{code = .Backspace} }
		return Key_Msg{code = .Rune, r = 'h', mods = {.Ctrl}}
	case '\t':
		if .Ctrl_I in legacy { return Key_Msg{code = .Rune, r = 'i', mods = {.Ctrl}} }
		return Key_Msg{code = .Tab}
	case '\r':
		if .Ctrl_M in legacy { return Key_Msg{code = .Rune, r = 'm', mods = {.Ctrl}} }
		return Key_Msg{code = .Enter}
	// ESC only reaches here via decode_keys' escape resolution (the raw byte is
	// intercepted earlier so it can introduce a sequence) and via direct calls.
	case 0x1b:
		if .Ctrl_Open_Bracket in legacy { return Key_Msg{code = .Rune, r = '[', mods = {.Ctrl}} }
		return Key_Msg{code = .Escape}
	case ' ':
		return Key_Msg{code = .Space, r = ' '}
	case 0x7f:
		if .Backspace in legacy { return Key_Msg{code = .Delete} }
		return Key_Msg{code = .Backspace}
	}
	// The remaining C0 bytes are Ctrl+<key>, but the offset is NOT uniform and
	// getting that wrong mis-names four real keys.
	//
	// SOH..SUB (0x01-0x1A) are Ctrl+a..Ctrl+z: the terminal strips bit 6 from
	// the LOWERCASE letter, so adding 0x60 back recovers it.
	//
	// FS..US (0x1C-0x1F) are Ctrl+\ Ctrl+] Ctrl+^ Ctrl+_ -- punctuation, not
	// letters. Those live at 0x5C-0x5F, so the offset is 0x40, not 0x60.
	// Applying the letter offset to them lands on 0x7C-0x7F: '|' '}' '~' and
	// DEL, none of which is a key the user pressed, and Ctrl+\ in particular is
	// a real binding (it is SIGQUIT's key on a cooked tty). ESC (0x1B) sits
	// between the two ranges and is handled by its own arm above.
	if b >= 0x1c && b <= 0x1f {
		return Key_Msg{code = .Rune, r = rune(b + 0x40), mods = {.Ctrl}}
	}
	return Key_Msg{code = .Rune, r = rune(b + 'a' - 1), mods = {.Ctrl}}
}

// The xterm modifier parameter is 1 + a bitmask, so an unmodified key is 1 and
// there is no valid 0. Returns ok = false for anything outside 1..=256, which
// keeps a stray numeric parameter (a device report that happens to end in a
// letter we recognise, say) from being forced into a plausible-looking
// modifier set.
//
// Bits above 8 -- Kitty's Hyper (16), Super (32), CapsLock (64), NumLock (128)
// -- are MASKED OFF, deliberately: Modifiers has no member for them, and
// mapping them onto the four we do have would report a modifier the user did
// not press. CSI 1;33A (Up with CapsLock latched) therefore decodes as plain
// Up, which is a lossy but honest answer. Decoding them properly is Kitty
// keyboard protocol work, which is out of T1-H's scope.
xterm_mods :: proc(param: int) -> (mods: Modifiers, ok: bool) {
	if param < 1 || param > 256 { return {}, false }
	mask := param - 1
	if mask & 1 != 0 { mods += {.Shift} }
	if mask & 2 != 0 { mods += {.Alt} }
	if mask & 4 != 0 { mods += {.Ctrl} }
	if mask & 8 != 0 { mods += {.Meta} }
	return mods, true
}

CSI_MAX_PARAMS :: 4

// Parses the parameter-byte run of a CSI (everything between "\e[" and the
// intermediate/final bytes) into at most CSI_MAX_PARAMS integers. A parameter
// that is present but empty ("\e[;5A") reports as -1 so callers can apply
// their own default, which is not the same as 0.
//
// Returns ok = false -- meaning "not a sequence this decoder assigns meaning
// to", NOT "malformed" -- for anything with a private prefix byte
// ('<' '=' '>' '?', i.e. mouse reports, DECRPM, Kitty flag queries) or a ':'
// sub-parameter separator (Kitty's key:shifted:base form). All of those are
// out of T1-H's scope and must fall through to the cleanly-ignored path with
// their byte length intact, which the caller computes independently of this
// proc.
csi_params :: proc(p: []u8) -> (params: [CSI_MAX_PARAMS]int, count: int, ok: bool) {
	for k in 0 ..< CSI_MAX_PARAMS { params[k] = -1 }
	if len(p) == 0 { return params, 0, true }
	count = 1
	for c in p {
		switch {
		case c >= '0' && c <= '9':
			d := int(c - '0')
			v := params[count - 1]
			if v < 0 { v = 0 }
			// No real key parameter exceeds three digits; the bound exists so
			// a long digit run in some unrecognised report cannot overflow
			// into a value that happens to look like a valid modifier.
			if v > 9999 { return params, 0, false }
			params[count - 1] = v * 10 + d
		case c == ';':
			if count >= CSI_MAX_PARAMS { return params, 0, false }
			count += 1
		case:
			return params, 0, false
		}
	}
	return params, count, true
}

// CSI <param>* ~ -- the "tilde" keys. Table from ultraviolet's key_table.go.
// 9, 10, 16, 22, 27 and 30 are unassigned; 25/26/28/29/31-34 are F13-F20,
// which Key_Code does not carry, so they report ok = false and get cleanly
// ignored rather than being folded onto some nearby F-key.
csi_tilde_code :: proc(param: int, legacy: Legacy_Key_Encoding) -> (code: Key_Code, ok: bool) {
	switch param {
	case 1:                           // "find" on VT220 keyboards
		if .Find in legacy { return .Find, true }
		return .Home, true
	case 2:  return .Insert, true
	case 3:  return .Delete, true
	case 4:                           // "select" on VT220 keyboards
		if .Select in legacy { return .Select, true }
		return .End, true
	case 5:  return .Page_Up, true
	case 6:  return .Page_Down, true
	case 7:  return .Home, true       // rxvt/urxvt
	case 8:  return .End, true        // rxvt/urxvt
	case 11 ..= 15: return Key_Code(int(Key_Code.F1) + param - 11), true
	case 17 ..= 21: return Key_Code(int(Key_Code.F6) + param - 17), true
	case 23, 24:    return Key_Code(int(Key_Code.F11) + param - 23), true
	}
	return .Rune, false
}

// The letter-final CSI keys: CSI <final>, CSI 1 <final>, CSI 1 ; <mod> <final>.
// 'R' is F3, which collides with a cursor position report (CSI <row>;<col> R);
// see decode_keys' doc comment.
csi_letter_code :: proc(final: u8) -> (code: Key_Code, ok: bool) {
	switch final {
	case 'A': return .Up, true
	case 'B': return .Down, true
	case 'C': return .Right, true
	case 'D': return .Left, true
	case 'F': return .End, true
	case 'H': return .Home, true
	case 'P': return .F1, true
	case 'Q': return .F2, true
	case 'R': return .F3, true
	case 'S': return .F4, true
	}
	return .Rune, false
}

// Decodes one COMPLETE CSI whose parameter bytes are `p` and whose final byte
// is `final`. `has_intermed` says whether any intermediate byte (0x20-0x2F)
// was present; every key form this decoder knows has none, so an intermediate
// byte is an immediate "not a key" (it is DECRPM, urxvt's CSI <n> $, ...).
//
// ok = false means "complete, but not a key this decoder understands" -- the
// caller consumes the sequence and emits nothing. It never means "incomplete";
// incompleteness is decided by the caller before this proc is reached.
csi_decode :: proc(p: []u8, has_intermed: bool, final: u8, legacy: Legacy_Key_Encoding) -> (key: Key_Msg, ok: bool) {
	if has_intermed { return {}, false }
	params, count := csi_params(p) or_return

	if final == '~' {
		if count == 0 || count > 2 { return {}, false }
		code := csi_tilde_code(params[0], legacy) or_return
		if count == 1 { return Key_Msg{code = code}, true }
		mods := xterm_mods(params[1]) or_return
		return Key_Msg{code = code, mods = mods}, true
	}

	code := csi_letter_code(final) or_return
	if count == 0 { return Key_Msg{code = code}, true }
	if count > 2 { return {}, false }
	// The first parameter of a modified cursor/function key is always 1 (the
	// "one key" repeat count); anything else is a different sequence that
	// happens to share our final byte -- a cursor position report, most
	// importantly -- and must not be decoded as a key.
	id := params[0]
	if id < 0 { id = 1 }
	if id != 1 { return {}, false }
	if count == 1 { return Key_Msg{code = code}, true }
	mods := xterm_mods(params[1]) or_return
	return Key_Msg{code = code, mods = mods}, true
}

// SS3: ESC O <digits>* <GL byte>. The digit run is the same 1+bitmask
// modifier xterm uses in CSI (some xterm configurations emit ESC O 5 P for
// Ctrl+F1); absent digits mean no modifiers.
//
// Keypad keys (ESC O M/X/j-y, DECKPAM) and ESC O E (Begin) have no Key_Code,
// so they report ok = false and are cleanly ignored. Lowercase a-d (rxvt's
// Ctrl+arrows) are likewise not decoded -- rxvt-specific key tables are out of
// T1-H's scope.
ss3_decode :: proc(mod_digits: []u8, gl: u8) -> (key: Key_Msg, ok: bool) {
	code: Key_Code
	switch gl {
	case 'A': code = .Up
	case 'B': code = .Down
	case 'C': code = .Right
	case 'D': code = .Left
	case 'F': code = .End
	case 'H': code = .Home
	case 'P': code = .F1
	case 'Q': code = .F2
	case 'R': code = .F3
	case 'S': code = .F4
	case:     return {}, false
	}
	if len(mod_digits) == 0 { return Key_Msg{code = code}, true }
	v := 0
	for c in mod_digits {
		if v > 9999 { return {}, false }
		v = v * 10 + int(c - '0')
	}
	mods := xterm_mods(v) or_return
	return Key_Msg{code = code, mods = mods}, true
}

// Decodes as many complete keys as `data` contains, appending to `out`.
// Returns the number of bytes consumed; a trailing partial escape sequence
// or a trailing partial UTF-8 rune is left unconsumed so the caller can
// retry once more bytes arrive.
//
// Vocabulary: printable runes; C0 control bytes per decode_c0's policy;
// Enter/Tab/Space/Backspace/Escape; arrows, Home, End, Page_Up, Page_Down,
// Insert, Delete and F1-F12 in their CSI-tilde, CSI-letter and SS3 encodings;
// and xterm modifier parameters (Shift/Alt/Ctrl/Meta) on all of those.
//
// DOCUMENTED LIMITATIONS -- each of these is a separate future unit, and each
// is CLEANLY IGNORED here (consumed whole, nothing emitted) rather than
// leaking bytes as garbage runes:
//   - mouse reporting (X10, SGR: CSI M ..., CSI < ... M/m);
//   - bracketed paste (CSI 200~ / CSI 201~ and the text between them);
//   - the Kitty keyboard protocol (CSI u, CSI ? <flags> u, and the ':'
//     sub-parameter form), including its Hyper/Super/CapsLock/NumLock
//     modifier bits -- see xterm_mods for why those are masked off;
//   - focus in/out (CSI I / CSI O);
//   - keypad/DECKPAM keys (ESC O M/X/j-y) and Begin (CSI E / ESC O E);
//   - Shift+Tab (CSI Z) and rxvt's lowercase-letter arrow forms;
//   - F13-F20 (CSI 25~ and up), which Key_Code does not carry;
//   - terminfo. The tables here are the xterm/VT220 defaults, not the
//     terminal's own key table; a terminal that reports something else is a
//     terminal this decoder does not fully understand. See the real-terminal
//     capture note in the T1-H report.
//   - cursor position reports. CSI <row>;<col> R and modified-F3
//     (CSI 1;<mod> R) are the same bytes when row == 1, and this decoder
//     resolves them as F3 because RuneTea never issues a DSR 6n. If that ever
//     changes, this is the collision to revisit; ultraviolet handles it by
//     emitting BOTH events, which needs a Msg vocabulary we do not have yet.
//
// HOLD-BACK CONTRACT (the subtle part): a sequence that is still arriving --
// "\e" alone at the very end of the buffer, "\e[" with nothing after it, a
// CSI whose final byte (0x40-0x7E) hasn't arrived yet, an SS3 whose GL byte
// hasn't arrived yet, or a UTF-8 lead byte without all of its continuation
// bytes yet -- must NOT be decoded yet. Emitting a spurious Escape, or a
// spurious U+FFFD replacement rune, for any of these would be the classic bug
// where a sequence split across two reads turns into a bogus keypress plus
// garbage once the rest of it arrives and gets decoded on its own. Every "not
// enough bytes yet" case below returns early with `consumed` short of
// `len(data)`, and Task 10's reader loop retries the undecoded tail once more
// bytes land. input_test.odin's test_split_at_every_byte_boundary feeds every
// proper prefix of every sequence in the key table through here and asserts
// exactly this.
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
// "\eO" AT THE END OF THE BUFFER IS THE SAME EXCEPTION, not a second one.
// ESC O is both the SS3 introducer and Alt+Shift+O, so unlike "\e[" the two
// bytes in hand do NOT positively identify a sequence in progress -- they are
// a complete, plausible keypress on their own. With no third byte present it
// therefore resolves immediately, exactly as the lone ESC above does, and for
// exactly the same reason: only a timer could tell "sequence in flight" from
// "key pressed", and there is no timer. When a third byte IS present, SS3
// wins, because ESC O followed by anything is overwhelmingly more likely to
// be a function/arrow key than Alt+O followed by an unrelated keystroke
// inside one read. The cost is that Alt+O immediately followed by another
// keystroke is swallowed as an unrecognised SS3 -- accepted, and pinned by
// test_esc_o_ambiguity.
//
// THE ASYMMETRY IS DELIBERATE: "\e[" at end-of-buffer holds back, "\eO"
// resolves. "\e[" is never a key on its own (there is no Alt+[ that a
// terminal encodes as ESC [ -- that byte pair is unconditionally the CSI
// introducer, which is why every terminal escapes a literal Alt+[ some other
// way), so holding it back costs nothing and risks nothing. "\eO" is a key on
// its own, so holding it back would mean silently dropping a real keypress
// whenever the user's next keystroke never comes.
//
// It also reports Alt+O as Rune 'O' + {.Alt}, NOT as lowercase 'o' +
// {.Alt, .Shift} the way ultraviolet does. That is a deliberate deviation:
// this decoder's generic Alt+printable path (below) reports ESC-then-'P' as
// Rune 'P' + {.Alt}, and a decoder where 'O' alone came out in a different
// shape from every other uppercase letter would be a trap for anyone writing
// a key binding.
//
// LEGACY FLAGS AND THE ESC PATH (the trap). `legacy` reaches decode_c0 at the
// C0 gate below and csi_decode for CSI 1~/4~. Ctrl_Open_Bracket is the odd one
// out: ESC is intercepted HERE, above the C0 gate, because it also introduces
// sequences. So the flag applies at exactly the two points where an Escape is
// RESOLVED -- the lone-ESC-at-end-of-buffer case and the double-ESC case, both
// of which call decode_c0(0x1b, legacy) instead of building a Key_Msg inline,
// so there is one answer, not three. It must NOT touch the hold-back decisions,
// the ESC [ / ESC O grammars, or the Alt+key path: where a sequence ends is
// decided by the BYTES, and renaming a resolved Escape cannot change that.
// Getting this wrong silently breaks every escape sequence, so
// test_ctrl_open_bracket_leaves_sequences_alone pins it specifically.
//
// A second ESC arriving immediately after the first ("\e\e", e.g. a user
// double-tapping Escape in a modal/vim-like UI) is likewise not ambiguous:
// it is treated as a real Escape keypress, and the second ESC byte is left
// for the next loop iteration to resolve on its own terms -- as a lone
// trailing Escape, as the start of a new sequence, or as another double-ESC.
decode_keys :: proc(data: []u8, out: ^[dynamic]Key_Msg, legacy: Legacy_Key_Encoding = {}) -> (consumed: int) {
	i := 0
	for i < len(data) {
		b := data[i]

		if b == 0x1b {
			if i + 1 >= len(data) {
				// Lone ESC at the very end of the buffer. Ambiguous: it may be a
				// real Escape or the start of a sequence still in flight. The
				// spike resolves it as Escape; a timer-based disambiguation is
				// T1 work (spec §12).
				append(out, decode_c0(0x1b, legacy))
				return i + 1
			}
			if data[i + 1] == '[' {
				// CSI grammar: ESC [ <parameter bytes 0x30-0x3F>*
				//                    <intermediate bytes 0x20-0x2F>*
				//                    <final byte 0x40-0x7E>
				// Scan to the final byte first, WITHOUT interpreting any
				// parameters: that is what decides where the sequence ends,
				// and therefore whether to hold it back at all. Only once the
				// whole sequence is in hand does csi_decode get to say what it
				// means -- so "not a key we know" and "not here yet" can never
				// be confused for each other.
				ps := i + 2
				j  := ps
				for j < len(data) && data[j] >= 0x30 && data[j] <= 0x3F { j += 1 }
				pe := j
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
				if key, ok := csi_decode(data[ps:pe], pe != j, final, legacy); ok {
					append(out, key)
				}
				// Whether decoded or not, the sequence is consumed as ONE unit
				// -- "cleanly ignore an unsupported key" rather than leaking
				// its trailing bytes as garbage rune keypresses.
				i = j + 1
				continue
			}
			if data[i + 1] == 'O' {
				if i + 2 >= len(data) {
					// ESC O with no third byte: resolve as Alt+O. See the ESC O
					// discussion in this proc's doc comment -- this is the lone-ESC
					// exception again, not a new one.
					append(out, Key_Msg{code = .Rune, r = 'O', mods = {.Alt}})
					return i + 2
				}
				// SS3 grammar: ESC O <digits>* <GL byte 0x21-0x7E>.
				ds := i + 2
				j  := ds
				for j < len(data) && data[j] >= '0' && data[j] <= '9' { j += 1 }
				if j >= len(data) { return i }   // GL byte not arrived yet: hold back
				gl := data[j]
				if gl < 0x21 || gl > 0x7E {
					// Same resynchronisation rule as a malformed CSI above.
					i += 2
					continue
				}
				if key, ok := ss3_decode(data[ds:j], gl); ok {
					append(out, key)
				}
				i = j + 1
				continue
			}
			if data[i + 1] == 0x1b {
				// Double Escape: resolve the first as a real Escape keypress
				// and leave the second ESC byte for the next iteration.
				append(out, decode_c0(0x1b, legacy))
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

		// 0x00-0x20 and 0x7F: one policy, one place. See decode_c0.
		if b <= 0x20 || b == 0x7f {
			append(out, decode_c0(b, legacy))
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
