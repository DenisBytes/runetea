package runetea

import "core:unicode/utf8"

// Press MUST stay the zero value: every legacy decode path builds a Key_Msg
// without naming `kind`, so reordering this enum would silently relabel every
// keypress the decoder produces. Repeat is APPENDED for that reason, even
// though "Press, Repeat, Release" reads better -- test_key_kind_press_is_the
// _zero_value pins it.
//
// Repeat only ever occurs under the Kitty keyboard protocol with event types
// enabled; the legacy encoding has no way to express "the terminal's key
// auto-repeat fired" and reports a repeat as an ordinary Press.
Key_Kind :: enum u8 { Press, Release, Repeat }

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
	// T1-L: true for every rune that arrived between a bracketed-paste
	// `CSI 200~` and its `CSI 201~`. APPENDED, like every other member in this
	// file, and false is the zero value, so every existing decode path keeps
	// producing exactly what it did.
	//
	// A pasted key is always `code = .Rune` with `mods = {}`: inside a paste
	// the bytes are TEXT, so no escape sequence is decoded and no key semantics
	// are applied (see decode_keys). An application that ignores paste entirely
	// still receives the pasted text as ordinary keypresses, which is the
	// graceful degradation this design is built around.
	pasted: bool,
}

// Bracketed paste's boundaries. ZERO-SIZED ON PURPOSE, and the reason is
// box()'s MESSAGE OWNERSHIP CONTRACT (arena.odin): Bubble Tea's
// `PasteMsg{Content string}` is ILLEGAL here, because box() rejects a `string`
// field at runtime, and Msg_Text is not a workaround -- it truncates at 255
// bytes and pastes routinely run to kilobytes.
//
// So the content is STREAMED instead: between these two messages the pasted
// text arrives as ordinary Key_Msgs with `pasted = true`. That is O(1) memory
// for an arbitrarily large paste (accumulating it would mean holding the whole
// thing in the reader's `pending` buffer, unbounded, before emitting anything)
// and it arrives incrementally rather than all at the end.
Paste_Start_Msg :: struct{}
Paste_End_Msg   :: struct{}

// Where a paste boundary sits RELATIVE TO THE KEYS decode_keys emitted in the
// same call: the marker belongs immediately before `out[at]`, and `at ==
// len(out)` means "after everything".
//
// Positions rather than a second, unordered output stream (which is what
// `enh` is) because ORDER IS THE POINT here. An application that switches into
// a bulk-insert mode on Paste_Start_Msg needs it before the first pasted
// character, not after the last one; the keyboard-enhancement reply has no
// such requirement, arrives once, and can afford to be reported out of band.
Paste_Marker :: struct {
	at:    int,
	start: bool,   // true = Paste_Start_Msg, false = Paste_End_Msg
}

// decode_keys' bracketed-paste state AND its marker output, in one struct
// because a caller needs both or neither.
//
// `active` is DECODER STATE THAT MUST PERSIST ACROSS CALLS. The reader calls
// decode_keys once per read(), and a paste of any size straddles reads, so
// "am I inside a paste?" cannot live in a local. It is not a package-level
// global either: there is more than one decoder in this process (run() and
// run_nbio() each own a reader, and tests call decode_keys directly), and a
// shared global would have one reader's paste swallow another's keystrokes.
// The caller owns the struct; both event-loop hosts keep one next to their
// `pending` buffer.
//
// `markers` is CALLER-CLEARED, exactly like `out` and `enh`: decode_keys only
// appends. Delete it when done -- it is the one allocation this type owns.
Paste_State :: struct {
	active:  bool,
	markers: [dynamic]Paste_Marker,
}

// Boxes a Paste_Marker as the Msg it denotes. Package-visible because both
// event-loop hosts need it and Odin has no closures to share the branch with;
// context.allocator (never the frame arena) because these cross a thread
// boundary into the mailbox like every other Msg -- see arena.odin's LIFETIME
// CONTRACT. Both types are zero-sized, so box() returns a nil-data `any` and
// box_free no-ops on it, exactly as it already does for Quit_Msg.
@(private = "package")
paste_marker_box :: proc(m: Paste_Marker) -> any {
	if m.start { return box(Paste_Start_Msg{}, context.allocator) }
	return box(Paste_End_Msg{}, context.allocator)
}

// The two bracketed-paste sequences, as strings so decode_keys can compare a
// still-arriving tail against a prefix of PASTE_END without any arithmetic.
@(private = "file")
PASTE_START :: "\e[200~"
@(private = "file")
PASTE_END   :: "\e[201~"

// What the terminal answered when term_enter_raw asked "CSI ? u" which
// keyboard enhancements it actually enabled. `flags` is the terminal's word,
// not ours: a terminal is free to enable fewer flags than were pushed, and one
// with no Kitty support at all never replies, so an app that gets no
// Keyboard_Enhancements_Msg is on the legacy encoding. Bubble Tea's
// KeyboardEnhancementsMsg, ported -- its SupportsEventTypes() and friends are
// spelled `.Report_Event_Types in msg.flags` here.
//
// POD, and it has to be: box() rejects anything with a pointer in it (see
// arena.odin's MESSAGE OWNERSHIP CONTRACT), and this crosses a thread boundary
// through the mailbox like every other Msg. Kitty_Flags is a bit_set over u8,
// so this is 1 byte with nothing to own.
Keyboard_Enhancements_Msg :: struct {
	flags: Kitty_Flags,
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
// Bits above 8 are MASKED OFF, deliberately: Modifiers has no member for them,
// and mapping them onto the four we do have would report a modifier the user
// did not press. CSI 1;33A therefore decodes as plain Up, which is a lossy but
// honest answer.
//
// THIS IS NOT THE KITTY BITMASK -- see kitty_mods, which is a different
// function of the same-shaped number. Bit 8 here is Meta (xterm's meaning);
// bit 8 in Kitty is Super and Meta moves to bit 32. Sharing one proc between
// the two encodings would mis-name a modifier on every Kitty event that has
// one, which is precisely why there are two.
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
// sub-parameter separator. Those must fall through to the cleanly-ignored path
// with their byte length intact, which the caller computes independently of
// this proc.
//
// THE ':' REJECTION IS LOAD-BEARING AND STAYS, and it has now survived two
// features that each "needed" sub-parameters. T1-J added Kitty CSI-u decoding
// and gave it its OWN parser (kitty_params), reached only from the 'u' final
// byte. T1-K added Kitty's event-type extension on the LEGACY finals
// (`CSI 1;5:3A`) and did it with a separate PASS (csi_event_type) that strips
// the sub-parameter before this proc ever sees the bytes. Neither widened this
// one, because sub-parameters appear in plenty of sequences that are not keys
// at all -- SGR colour with `38:2::r:g:b`, DECRPM replies, SGR mouse -- and
// every one of them lands on the cleanly-ignored path BECAUSE of this
// rejection. Accepting ':' here would silently promote them to "parsed", with
// the sub-parameter values read as though they were ';'-separated parameters:
// `CSI <0;10:5M` would become a plausible-looking something instead of an
// ignored mouse report. test_subparams_are_rejected_outside_csi_u pins it, and
// test_csi_params_still_rejects_colons pins this proc directly.
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

// Kitty's EVENT-TYPE EXTENSION ON THE LEGACY ENCODINGS, split off ahead of
// csi_params so that csi_params' ':' rejection can stay exactly as strict as
// it is (read its comment: that rejection is what keeps SGR colour, SGR mouse
// and DECRPM replies on the cleanly-ignored path, and widening it would
// silently reinterpret their sub-parameters as ';' parameters).
//
// With Report_Event_Types enabled, a terminal does NOT switch modified arrows
// and tilde keys to CSI-u; it keeps the legacy form and hangs the event type
// off the modifier field as a sub-parameter:
//
//   CSI 1;5:3 A     Ctrl+Up, RELEASE          CSI 3;5:3 ~   Ctrl+Delete, release
//   CSI 1;1:2 A     Up, auto-repeat
//
// So this strips " : <event-type>" off the end of the parameter run and hands
// back the plain "1;5" head for the ordinary parsers, plus the Key_Kind it
// encoded. Port of ultraviolet's parseKittyKeyboardExt (decoder.go), with its
// shape requirements made explicit rather than falling out of a params API:
//
//   - the ':' must sit in the SECOND ';' field, i.e. exactly one ';' before
//     it. That is the modifier field, the only place the extension puts it.
//     `CSI 1:2 A` (a sub-parameter on the key field) is not this grammar and
//     stays cleanly ignored, as does anything with a private prefix, since the
//     head still has to survive csi_params afterwards;
//   - exactly ONE sub-parameter follows, digits only. A second ':' means some
//     other grammar we do not know, and guessing at it would be how a mouse or
//     colour sequence gets promoted to a fake keypress.
//
// Value mapping matches kitty_decode's exactly -- 2 repeat, 3 release, absent/
// empty/anything else press -- because the two are the same protocol field
// reached by two routes, and a decoder that called `CSI 97;1:9u` a press but
// `CSI 1;1:9A` a nothing would be indefensible.
csi_event_type :: proc(p: []u8) -> (head: []u8, kind: Key_Kind, ok: bool) {
	colon := -1
	semis := 0
	for c, k in p {
		switch c {
		case ':':
			if colon >= 0 { return nil, .Press, false }   // a second ':': not this grammar
			colon = k
		case ';':
			if colon >= 0 { return nil, .Press, false }   // ';' AFTER the ':': not this grammar
			semis += 1
		}
	}
	if colon < 0 { return p, .Press, true }               // no sub-parameter at all: the common case
	if semis != 1 { return nil, .Press, false }           // not on the modifier field

	v := 0
	for c in p[colon + 1:] {
		if c < '0' || c > '9' { return nil, .Press, false }
		if v > 9999 { return nil, .Press, false }
		v = v * 10 + int(c - '0')
	}
	switch v {
	case 2: return p[:colon], .Repeat, true
	case 3: return p[:colon], .Release, true
	}
	return p[:colon], .Press, true
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

// ---------------------------------------------------------------------------
// T1-J: the Kitty keyboard protocol, DECODE SIDE ONLY.
//
// Wire format, all three fields optional past the first:
//
//   CSI <key> [: <shifted> : <base-layout>] [; <mods> [: <event-type>]]
//             [; <text-codepoint> [: <text-codepoint>]*] u
//
// The point of the protocol is that it REMOVES the legacy collisions rather
// than arbitrating them the way Legacy_Key_Encoding does: Tab is CSI 9 u and
// Ctrl+I is CSI 105;5 u, Enter is CSI 13 u and Ctrl+M is CSI 109;5 u, Escape
// is CSI 27 u and Ctrl+[ is CSI 91;5 u. They are simply different byte strings,
// so nothing here consults `legacy` -- doing so would put back the ambiguity
// the terminal just went to the trouble of eliminating.
//
// T1-K TURNED IT ON. term_enter_raw(fd, kb) pushes `CSI > <flags> u` when the
// application opts in (term.odin), and only then does a terminal start
// emitting CSI-u key events -- decoding stayed unconditional and simply went
// from inert to live. Decoding is still safe with the protocol OFF for the
// same reason it always was: the only CSI-u form a terminal sends unbidden is
// the flags reply, which carries a private prefix byte kitty_params rejects
// and kitty_flags_reply handles as its own Msg.
// ---------------------------------------------------------------------------

// The Kitty modifier parameter is 1 + a bitmask, same shape as xterm's and a
// DIFFERENT function -- getting this wrong is the single easiest way to ship a
// plausible-looking decoder that names the wrong modifier:
//
//   bit    1     2    4     8      16     32    64        128
//   Kitty  Shift Alt  Ctrl  Super  Hyper  Meta  CapsLock  NumLock
//   xterm  Shift Alt  Ctrl  Meta   --     --    --        --
//
// Super, Hyper, CapsLock and NumLock are MASKED OFF for the same reason
// xterm_mods masks off its high bits: Modifiers has no member for them, and
// folding Super onto Meta (which the shared bit position invites) would report
// a modifier the user did not press. So Ctrl+Super+a decodes as Ctrl+a: lossy,
// but never wrong about what it does report.
//
// Out of range is rejected rather than clamped, matching xterm_mods, so a
// sequence carrying a nonsense modifier field is cleanly ignored instead of
// being forced into a plausible-looking key event.
kitty_mods :: proc(param: int) -> (mods: Modifiers, ok: bool) {
	if param < 1 || param > 256 { return {}, false }
	mask := param - 1
	if mask &  1 != 0 { mods += {.Shift} }
	if mask &  2 != 0 { mods += {.Alt} }
	if mask &  4 != 0 { mods += {.Ctrl} }
	if mask & 32 != 0 { mods += {.Meta} }
	return mods, true
}

// Is `code` a codepoint that can stand as a Key_Msg.r? Excludes the C0/DEL
// controls (which have their own named codes), the UTF-16 surrogate range and
// anything past U+10FFFF (neither is a Unicode scalar value, so rune(code)
// would be a lie), and the BMP private-use area -- that last one is Kitty's
// functional-key space, and letting a keycode fall through to "printable rune"
// would turn an unmapped F13 into a garbage glyph instead of the documented
// clean ignore.
kitty_printable :: proc(code: int) -> bool {
	switch {
	case code < 0x20 || code == 0x7f:         return false
	case code > 0x10ffff:                     return false
	case code >= 0xd800 && code <= 0xdfff:    return false   // surrogates
	case code >= 0xe000 && code <= 0xf8ff:    return false   // Kitty functional-key PUA
	}
	return true
}

// The unicode-key-code -> Key_Msg mapping. ok = false means "a real Kitty key
// this decoder has no vocabulary for": the caller consumes the sequence and
// emits nothing, per the decoder's standing policy for unsupported keys.
//
// Three bands:
//   0x00-0x1F, 0x7F -- NOT spec-conformant (a compliant terminal sends the
//     functional codes below), but WezTerm and others send the historical C0
//     byte, so ultraviolet carries a table for them and so do we. The values
//     match decode_c0's arithmetic exactly (0x01-0x1A take the 0x60 letter
//     offset, 0x1C-0x1F the 0x40 punctuation offset) so the two paths cannot
//     drift -- with ONE deliberate difference: 0x08 is Backspace here, not
//     Ctrl+h. Under Kitty, Ctrl+h is 104;5 and cannot collide with it, so
//     there is no ambiguity left for Legacy_Key.Backspace to arbitrate.
//   0x20-0x10FFFF -- an ordinary text key, reported as itself.
//   57344+ (0xE000+) -- the functional keys. Only the ones Key_Code carries
//     are mapped; F13-F35, the keypad block, the media keys and the lone
//     modifier keypresses (57441-57454, which a terminal sends when the user
//     merely TAPS Shift) are cleanly ignored. Adding Key_Code members for them
//     is a vocabulary change, not a decoder change, and is not T1-J's job.
kitty_key_code :: proc(code: int) -> (key: Key_Msg, ok: bool) {
	switch code {
	case 0:     return Key_Msg{code = .Space, mods = {.Ctrl}}, true   // Ctrl+Space produces no text
	case 8:     return Key_Msg{code = .Backspace}, true
	case 9:     return Key_Msg{code = .Tab}, true
	case 13:    return Key_Msg{code = .Enter}, true
	case 27:    return Key_Msg{code = .Escape}, true
	case 32:    return Key_Msg{code = .Space, r = ' '}, true
	case 127:   return Key_Msg{code = .Backspace}, true

	case 57344: return Key_Msg{code = .Escape}, true
	case 57345: return Key_Msg{code = .Enter}, true
	case 57346: return Key_Msg{code = .Tab}, true
	case 57347: return Key_Msg{code = .Backspace}, true
	case 57348: return Key_Msg{code = .Insert}, true
	case 57349: return Key_Msg{code = .Delete}, true
	case 57350: return Key_Msg{code = .Left}, true
	case 57351: return Key_Msg{code = .Right}, true
	case 57352: return Key_Msg{code = .Up}, true
	case 57353: return Key_Msg{code = .Down}, true
	case 57354: return Key_Msg{code = .Page_Up}, true
	case 57355: return Key_Msg{code = .Page_Down}, true
	case 57356: return Key_Msg{code = .Home}, true
	case 57357: return Key_Msg{code = .End}, true
	}
	// The C0 ranges, as if-checks rather than switch ranges: 8/9/13/27 sit
	// inside 1..=26 and Odin rejects a switch whose cases overlap.
	if code >= 1  && code <= 26 { return Key_Msg{code = .Rune, r = rune(code + 0x60), mods = {.Ctrl}}, true }
	if code >= 28 && code <= 31 { return Key_Msg{code = .Rune, r = rune(code + 0x40), mods = {.Ctrl}}, true }
	// F1-F12. Contiguous by construction -- see Key_Code's comment on why the
	// F-block's order is load-bearing.
	if code >= 57364 && code <= 57375 {
		return Key_Msg{code = Key_Code(int(Key_Code.F1) + code - 57364)}, true
	}
	if !kitty_printable(code) { return {}, false }
	return Key_Msg{code = .Rune, r = rune(code)}, true
}

// Kitty's parameter grid: up to KITTY_MAX_FIELDS ';'-separated fields, each
// with ':'-separated sub-parameters. Values are -1 when the slot is present but
// empty ("\e[97;;98u" has an empty modifier field), which is NOT the same as 0.
//
// `nsub` counts sub-parameters even past what `v` can store, because the text
// field's COUNT is what decides whether it is usable (see kitty_decode).
KITTY_MAX_FIELDS :: 3
KITTY_MAX_SUBS   :: 3

Kitty_Params :: struct {
	v:      [KITTY_MAX_FIELDS][KITTY_MAX_SUBS]int,
	nsub:   [KITTY_MAX_FIELDS]int,
	nfield: int,
}

// Parses the parameter-byte run of a `CSI ... u`. ok = false means "not a
// Kitty key event"; the caller consumes the sequence whole and emits nothing.
//
// THE PRIVATE-PREFIX REJECTION IS THE WHOLE REASON THIS IS SAFE TO RUN
// UNCONDITIONALLY. Every non-key CSI-u form carries a prefix byte where a digit
// belongs -- CSI ? <flags> u (the flags-query reply, which a terminal sends of
// its own accord), CSI = <flags> ; <mode> u, CSI > <flags> u, CSI < <n> u --
// and the default arm below rejects all four along with anything else that is
// not a digit, ';' or ':'. Reading the prefix byte as part of a parameter would
// report a terminal's flags word as a keypress.
//
// An empty parameter run is likewise not a key: bare `CSI u` has no keycode.
kitty_params :: proc(p: []u8) -> (kp: Kitty_Params, ok: bool) {
	for f in 0 ..< KITTY_MAX_FIELDS {
		for s in 0 ..< KITTY_MAX_SUBS { kp.v[f][s] = -1 }
	}
	if len(p) == 0 { return kp, false }
	kp.nfield  = 1
	kp.nsub[0] = 1
	f, s := 0, 0
	for c in p {
		switch {
		case c >= '0' && c <= '9':
			// Sub-parameters past what `v` holds still advance nsub (above);
			// their digits are simply dropped, since nothing reads them.
			if s >= KITTY_MAX_SUBS { continue }
			d := int(c - '0')
			val := kp.v[f][s]
			if val < 0 { val = 0 }
			// Bounded by the largest legal Unicode scalar value, not by the
			// three digits csi_params allows: the text field carries real
			// codepoints and U+10FFFF is seven of them. Checking before the
			// multiply keeps the accumulator far from overflow.
			if val > 0x10ffff { return kp, false }
			kp.v[f][s] = val * 10 + d
		case c == ':':
			s += 1
			kp.nsub[f] = s + 1
		case c == ';':
			f += 1
			if f >= KITTY_MAX_FIELDS { return kp, false }
			kp.nfield  = f + 1
			kp.nsub[f] = 1
			s = 0
		case:
			return kp, false
		}
	}
	return kp, true
}

// `CSI ? <flags> u` -- the terminal's REPLY to the "CSI ? u" query
// term_enter_raw sends after pushing (term.odin). The only unsolicited CSI-u
// form a terminal produces, and the one member of the private-prefix family
// that is not a request: `CSI = ... u` (set), `CSI > ... u` (push) and
// `CSI < ... u` (pop) are things a PROGRAM writes, so seeing one on the input
// stream means something echoed our own output back, and decoding it would
// report the flags we asked for as though the terminal had confirmed them.
// Hence the exact prefix match here instead of a "skip any private prefix"
// rule -- and test_kitty_non_key_csi_u_forms_are_ignored still pins the other
// three as cleanly ignored.
//
// The flags word is MASKED to the five bits Kitty_Flag defines. A terminal
// reporting a bit we have no name for is a terminal running a newer protocol
// revision than this decoder; dropping the bit is lossy but honest, and
// transmuting it in would produce a Kitty_Flags value with a set bit that no
// enum member covers, which is worse than lossy.
//
// A bare `CSI ? u` (no flags digits) is not a reply -- it is the QUERY, i.e.
// our own bytes echoed back -- and reports ok = false, leaving it on the
// cleanly-ignored path.
kitty_flags_reply :: proc(p: []u8) -> (flags: Kitty_Flags, ok: bool) {
	if len(p) < 2 || p[0] != '?' { return {}, false }
	v := 0
	for c in p[1:] {
		if c < '0' || c > '9' { return {}, false }
		if v > 9999 { return {}, false }
		v = v * 10 + int(c - '0')
	}
	// Bit n == Kitty_Flag(n) == protocol value 1<<n; see Kitty_Flag (term.odin).
	return transmute(Kitty_Flags)u8(v & 0x1f), true
}

// Decodes a COMPLETE `CSI <params> u` into a key event. See the block comment
// above for the wire format.
//
// TEXT CODEPOINTS AND THE ONE-RUNE LIMIT (requirement 5, answered honestly).
// The third field is the text the keypress produces, as one or more codepoints;
// Key_Msg.r is a single rune. When the field carries exactly one codepoint it
// becomes `r`. When it carries SEVERAL -- which is real for IMEs and for
// combining sequences, e.g. a dead-key composition arriving as base + combining
// mark -- the field is ignored WHOLESALE and `r` falls back to the key code.
// That is a deliberate choice over truncating to the first codepoint: a
// truncated "é" that arrives as 'e' + U+0301 would silently become a plain 'e'
// that the application cannot tell from a real 'e' keypress, whereas falling
// back to the key code at least reports the physical key honestly. Carrying
// multi-codepoint text properly needs a `text` field on Key_Msg (a Msg_Text
// style inline buffer, since Msg types must stay POD -- see arena.odin's
// is_pod check), which is a vocabulary change and not T1-J's job.
kitty_decode :: proc(p: []u8) -> (key: Key_Msg, ok: bool) {
	kp := kitty_params(p) or_return

	// Field 0 sub 0: the unicode key code. CSI u's documented default is 1.
	code := kp.v[0][0]
	if code < 0 { code = 1 }
	key = kitty_key_code(code) or_return

	// Field 0 sub 1: the SHIFTED codepoint, sub 2: the base-layout codepoint.
	// The shifted one wins for `r` because it is what the keypress actually
	// produces -- Shift+a arrives as 97:65 and must read as 'A', not 'a'.
	// The base-layout codepoint (what the same physical key would be on a
	// PC-101 US layout) has nowhere to live in Key_Msg and is dropped; it is
	// parsed only so its presence cannot shift the field indices.
	if key.code == .Rune && kp.nsub[0] >= 2 && kitty_printable(kp.v[0][1]) {
		key.r = rune(kp.v[0][1])
	}

	// Field 1 sub 0: modifiers. UNIONED with whatever the key code already
	// implied (the C0 band arrives carrying .Ctrl) rather than assigned, so a
	// terminal that sends `CSI 1 u` for Ctrl+a without a modifier field still
	// reports Ctrl.
	if kp.nfield >= 2 {
		m := kp.v[1][0]
		if m < 0 { m = 1 }                 // present but empty == unmodified
		key.mods += kitty_mods(m) or_return
		// Field 1 sub 1: the event type. Absent means press; an unrecognised
		// value also means press, since a key the terminal reports is a key the
		// user touched and dropping it would be worse than mislabelling it.
		if kp.nsub[1] >= 2 {
			switch kp.v[1][1] {
			case 2: key.kind = .Repeat
			case 3: key.kind = .Release
			}
		}
	}

	// Field 2: the text. See this proc's doc comment for the multi-codepoint
	// answer. Only overrides a .Rune key: a functional key's text field (if a
	// terminal ever sent one) has no rune to override.
	if kp.nfield >= 3 && kp.nsub[2] == 1 && key.code == .Rune && kitty_printable(kp.v[2][0]) {
		key.r = rune(kp.v[2][0])
	}
	return key, true
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

	// 'u' is the Kitty keyboard protocol's dispatch point, and it is routed
	// BEFORE csi_params on purpose: the Kitty grammar has ':' sub-parameters
	// that csi_params rejects by design (see its comment for why that rejection
	// stays). kitty_params is the only parser in this file that accepts them,
	// and 'u' is the only final byte that reaches it.
	//
	// The non-key CSI-u forms (CSI ? / = / > / < ... u -- flag reply, set, push,
	// pop) are rejected inside kitty_params by its private-prefix arm, so they
	// stay cleanly ignored exactly as they were before 'u' meant anything.
	if final == 'u' { return kitty_decode(p) }

	// Kitty's event-type sub-parameter rides on the LEGACY encodings too, so
	// it is peeled off here, before csi_params ever sees the bytes -- see
	// csi_event_type for the grammar and for why this is a separate pass
	// rather than a widening of csi_params. `head` is the parameter run with
	// the ":<event-type>" removed, which is what the two parsers below expect;
	// everything past this point is exactly the code that ran before, plus a
	// `kind` that is .Press for every sequence without the extension.
	head, kind := csi_event_type(p) or_return

	params, count := csi_params(head) or_return

	if final == '~' {
		if count == 0 || count > 2 { return {}, false }
		code := csi_tilde_code(params[0], legacy) or_return
		if count == 1 { return Key_Msg{kind = kind, code = code}, true }
		mods := xterm_mods(params[1]) or_return
		return Key_Msg{kind = kind, code = code, mods = mods}, true
	}

	code := csi_letter_code(final) or_return
	if count == 0 { return Key_Msg{kind = kind, code = code}, true }
	if count > 2 { return {}, false }
	// The first parameter of a modified cursor/function key is always 1 (the
	// "one key" repeat count); anything else is a different sequence that
	// happens to share our final byte -- a cursor position report, most
	// importantly -- and must not be decoded as a key.
	id := params[0]
	if id < 0 { id = 1 }
	if id != 1 { return {}, false }
	if count == 1 { return Key_Msg{kind = kind, code = code}, true }
	mods := xterm_mods(params[1]) or_return
	return Key_Msg{kind = kind, code = code, mods = mods}, true
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
// xterm modifier parameters (Shift/Alt/Ctrl/Meta) on all of those; the
// Kitty keyboard protocol's CSI-u key events, including press/repeat/release
// event types and the alternate-key and text sub-parameter forms; Kitty's
// event-type sub-parameter on the LEGACY encodings (CSI 1;5:3 A,
// CSI 3;5:3 ~); bracketed paste (CSI 200~ ... CSI 201~), whose content is
// streamed as Key_Msgs with `pasted = true` and whose boundaries land in
// `pst.markers`; and the terminal's keyboard-enhancement reply
// (CSI ? <flags> u), which is the one thing here that is not a Key_Msg and so
// goes to `enh` instead of `out`.
//
// `enh` is OPTIONAL and defaults to nil, which drops the reply on the
// cleanly-ignored path exactly as this decoder did before it understood it.
// The two output streams also mean ORDER BETWEEN THEM IS NOT PRESERVED: a
// buffer containing both keys and a reply reports all its keys, then the
// reply. Harmless in practice -- the reply arrives once, in answer to a query
// term_enter_raw writes before any key can be pressed -- and cheaper than the
// tagged-union output stream the alternative would need.
//
// TURNING KITTY ON is the application's call, via term_enter_raw(fd, kb)
// (term.odin). Decoding is unconditional and does not consult that: a terminal
// simply never emits these forms unless it was asked to.
//
// BRACKETED PASTE (T1-L) is the one construct here that is not a key at all.
// Between `CSI 200~` and `CSI 201~` the bytes are TEXT, and this decoder
// suspends BOTH of its usual jobs for the duration:
//   - no escape-sequence decoding. A pasted "\e[A" is three literal runes, NOT
//     Up. That is the entire bug the feature exists to fix: without it, pasting
//     a buffer that happens to contain an arrow sequence executes it;
//   - no key semantics. A pasted "\n" is Key_Msg{code = .Rune, r = '\n'}, not
//     Enter; likewise "\t" is not Tab and "\r" is not Enter. decode_c0 is never
//     consulted inside a paste. An application inserting the text wants a
//     newline CHARACTER in its buffer, not "the user pressed Enter".
// UTF-8 decoding does still apply -- a multi-byte rune must arrive intact, and
// one split across a read boundary still holds back. The ONLY thing that ends
// paste mode is the `CSI 201~` terminator; a nested `CSI 200~` is literal text.
//
// The state lives in `pst` (see Paste_State) because the reader calls this
// proc once per read and a paste of any size straddles reads. With pst == nil
// paste is still decoded WITHIN a single buffer, but the mode cannot survive
// the call and the markers have nowhere to go -- the same degradation
// enh == nil gives the enhancement reply.
//
// AN UNTERMINATED PASTE (the terminal dies or misbehaves mid-paste) does not
// wedge anything, and this is worth stating because "hold back" and "wedge"
// are one mistake apart. Everything decodable is consumed and emitted as it
// arrives; the only thing ever held back is an ambiguous tail of at most five
// bytes (a proper prefix of the terminator). So `pending` in the reader stays
// bounded, the loop keeps making progress, and the session ends the way any
// other does -- when read() reports EOF. What DOES persist is the mode itself:
// every subsequent keystroke arrives as pasted text until the process exits.
// Recovering from that would need a timeout, which is the same missing timer
// the lone-ESC rule below documents, so it is left as a documented limitation
// rather than half-solved with a guess.
//
// DOCUMENTED LIMITATIONS -- each of these is a separate future unit, and each
// is CLEANLY IGNORED here (consumed whole, nothing emitted) rather than
// leaking bytes as garbage runes:
//   - mouse reporting (X10, SGR: CSI M ..., CSI < ... M/m);
//   - an UNPAIRED `CSI 201~` (a paste end with no matching start). Reporting a
//     Paste_End_Msg for it would tell an application to leave a mode it never
//     entered -- the same class of hazard as term.odin's unpaired Kitty pop;
//   - the Kitty keyboard protocol's set/push/pop REQUESTS
//     (CSI = / > / < ... u). Those are bytes a program writes, so one arriving
//     on the input stream is an echo, not information. (The fourth member of
//     that family, the flags reply CSI ? <flags> u, IS decoded now -- see
//     kitty_flags_reply and `enh`.);
//   - Kitty's Super/Hyper/CapsLock/NumLock modifier bits, which Modifiers has
//     no member for -- see kitty_mods for why they are masked rather than
//     folded onto Meta;
//   - Kitty functional keys Key_Code has no member for: F13-F35, the whole
//     keypad block, the media keys, and the lone modifier keypresses;
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
//
// A BARE ESC AT THE END OF THE BUFFER *INSIDE A PASTE* GOES THE OTHER WAY: it
// HOLDS BACK. That is not an inconsistency with the lone-ESC rule above, it is
// the same trade-off evaluated against different stakes.
//
// Above, the two readings are "a real Escape keypress" and "a sequence in
// flight", and holding back would risk silently dropping a keypress that never
// gets a follow-up byte -- so the rule resolves, and the cost is a mis-decoded
// sequence in the rare split.
//
// Inside a paste, BOTH readings are text: either the ESC begins the `CSI 201~`
// terminator, or it is a literal ESC in the pasted content. There is no
// keypress to lose by waiting. And the two costs are wildly asymmetric --
// resolving it as literal text when it was the terminator emits a garbage rune,
// then re-emits "[201~" as five more, AND leaves the decoder stuck in paste
// mode for the rest of the session, whereas holding back costs at most a
// handful of bytes of latency in a burst that is by definition still arriving.
// Bounded, too: only a proper prefix of the terminator can stall, so at most
// five bytes are ever held (see the unterminated-paste note above).
decode_keys :: proc(
	data:   []u8,
	out:    ^[dynamic]Key_Msg,
	legacy: Legacy_Key_Encoding = {},
	enh:    ^[dynamic]Keyboard_Enhancements_Msg = nil,
	pst:    ^Paste_State = nil,
) -> (consumed: int) {
	// Mirrored into a local and written back on EVERY exit path (there are
	// several early returns for hold-back). With pst == nil the local is the
	// only state there is, which is what makes paste work within one buffer
	// but not across calls -- see this proc's doc comment.
	in_paste := pst != nil && pst.active
	defer { if pst != nil { pst.active = in_paste } }

	i := 0
	for i < len(data) {
		b := data[i]

		// PASTE CONTENT. Checked before everything else because inside a paste
		// none of the grammars below apply: the only structure left in the
		// stream is UTF-8 and the terminator.
		if in_paste {
			if b == 0x1b {
				// Is this the terminator, or literal text? Compare against as
				// much of PASTE_END as has actually arrived.
				// `end` is a runtime copy: Odin cannot slice a constant string
				// with a runtime index.
				end  := PASTE_END
				rest := data[i:]
				n := min(len(rest), len(end))
				if string(rest[:n]) == end[:n] {
					// Still a candidate. If the whole thing is not here yet,
					// hold back -- see the bare-ESC discussion above for why
					// this one waits where the top-level lone ESC resolves.
					if n < len(PASTE_END) { return i }
					in_paste = false
					if pst != nil { append(&pst.markers, Paste_Marker{at = len(out)}) }
					i += len(PASTE_END)
					continue
				}
				// Not the terminator, so the ESC is literal text. Emit just the
				// ESC and resynchronise on the next byte: whatever follows is
				// text too, and if it happens to begin a real terminator the
				// check above catches it on the next iteration. (xterm filters
				// ESC out of paste content; this decoder does not assume that.)
				append(out, Key_Msg{code = .Rune, r = rune(0x1b), pasted = true})
				i += 1
				continue
			}
			// Everything else is a literal rune -- including \n, \t, \r and the
			// rest of C0, which is why decode_c0 is deliberately NOT called
			// here. Only an incomplete UTF-8 rune holds back; the content is
			// otherwise streamed out in full on every call, because buffering it
			// is exactly what this design exists to avoid.
			need := utf8_lead_len(b)
			if i + need > len(data) { return i }
			r, w := utf8.decode_rune(data[i:])
			append(out, Key_Msg{code = .Rune, r = r, pasted = true})
			i += w
			continue
		}

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
				// `CSI ? <flags> u` is not a key and never was; before this
				// it fell through csi_decode to the cleanly-ignored path. It
				// is dispatched HERE rather than inside csi_decode because it
				// produces a different Msg type entirely, and csi_decode's
				// whole signature is "a Key_Msg or nothing". Consumption is
				// identical either way, so a caller that passes enh = nil
				// (every existing one, and the golden harness) sees precisely
				// the old behaviour.
				// Bracketed paste START. Dispatched here, next to the flags
				// reply and for the same reason: it is not a Key_Msg, so
				// csi_decode -- whose whole signature is "a Key_Msg or
				// nothing" -- has nowhere to put it. Matched against the WHOLE
				// sequence rather than its parameter run so intermediates and
				// private prefixes are excluded for free.
				//
				// The matching END is NOT handled here: while a paste is open
				// the branch at the top of the loop consumes it, and while one
				// is not, an unpaired `CSI 201~` falls straight through to
				// csi_decode, where csi_tilde_code has no entry for 201 and it
				// lands on the cleanly-ignored path exactly as it always did.
				if string(data[i:j + 1]) == PASTE_START {
					in_paste = true
					if pst != nil { append(&pst.markers, Paste_Marker{at = len(out), start = true}) }
					i = j + 1
					continue
				}
				if final == 'u' && pe == j {
					if fl, fok := kitty_flags_reply(data[ps:pe]); fok {
						if enh != nil { append(enh, Keyboard_Enhancements_Msg{flags = fl}) }
						i = j + 1
						continue
					}
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
