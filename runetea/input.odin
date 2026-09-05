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
// The four that follow Meta are the Kitty protocol's own, and they exist
// because "lossy but honest" had run out of road: `Modifiers` had four members
// against a wire encoding with eight, so every bit above 8 was masked off and
// `CSI 1;33A` -- Meta+Up from any terminal speaking Kitty's table -- arrived as
// a plain, unmodified Up. An application simply could not bind a Super key.
//
// EIGHT MEMBERS IS THE CEILING of the u8 backing, and that is deliberate rather
// than lucky: it is exactly the number of bits the wire has, so the set can now
// represent every modifier either encoding can express and there is no longer
// any masking to document.
//
// SUPER IS ONLY EVER PRODUCED BY THE KITTY PATH, and that is the one genuine
// ambiguity in the whole area rather than an omission -- see xterm_mods and
// kitty_mods, which disagree about bit 8 because xterm and Kitty disagree about
// bit 8. Caps_Lock and Num_Lock are LOCK STATES, not keys held down: they say
// what the keyboard's latches were at the moment of the press, so an
// application matching on `mods == {.Ctrl}` should mask them out rather than
// expect them absent.
Modifier  :: enum u8 { Ctrl, Alt, Shift, Meta, Super, Hyper, Caps_Lock, Num_Lock }
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

// ---------------------------------------------------------------------------
// T2-B: MOUSE REPORTING.
//
// Two wire encodings, both decoded unconditionally (a terminal only ever emits
// either one after term_enter_raw's opt-in asked it to -- the same reasoning
// that lets the Kitty CSI-u decoder run unconditionally):
//
//   SGR (DECSET 1006):  CSI < Cb ; Cx ; Cy M      press / drag / wheel
//                       CSI < Cb ; Cx ; Cy m      release
//   Legacy / X10:       CSI M <Cb+32> <Cx+32> <Cy+32>
//
// SGR is the one term_enter_raw asks for, because THE LEGACY ENCODING CANNOT
// EXPRESS A COLUMN PAST 223: it packs the coordinate into one byte as
// coordinate + 32, so column 224 needs byte 256 and simply wraps. Legacy is
// decoded anyway because a terminal that does not understand `?1006h` silently
// ignores it and keeps sending the old form -- the request is fire-and-forget,
// exactly like the Kitty push.
// ---------------------------------------------------------------------------

// Press is the zero value for the same reason Key_Kind.Press is: nothing here
// constructs a Mouse_Msg without naming `kind`, but keeping the two enums'
// defaults aligned means one less thing to get wrong when reading both.
Mouse_Kind :: enum u8 { Press, Release, Motion, Wheel }

// X11 button numbering, and NOT a bit_set: a mouse report names exactly one
// button (or none), unlike Modifiers, which genuinely is a set.
//
// None is the ZERO VALUE and is a real, reachable answer, not a filler: a
// motion event with no button held reports it, and so does every LEGACY
// release -- see x10_mouse for that asymmetry. Members are APPENDED and the
// three runs (Left..Right, Wheel_Up..Wheel_Right, Backward..Button_11) are
// each contiguous and in protocol order, because mouse_button_bits indexes
// into them with `first + (Cb & 3)`. Reordering silently renames buttons.
Mouse_Button :: enum u8 {
	None,
	Left, Middle, Right,
	Wheel_Up, Wheel_Down, Wheel_Left, Wheel_Right,
	Backward, Forward, Button_10, Button_11,
}

// COORDINATES ARE ZERO-BASED, (0,0) at the upper-left cell -- both wire
// encodings are one-based and both are normalised here. This matches
// ultraviolet's Mouse and Bubble Tea's, and it matches render.odin's Cursor,
// whose `line`/`col` are also zero-based, so an app can compare a click against
// a caret without an off-by-one conversion in between.
//
// POD, and it has to be: box() rejects anything with a pointer in its field
// tree (arena.odin's MESSAGE OWNERSHIP CONTRACT) and this crosses a thread
// boundary through the mailbox like every other Msg. Two enums, two ints and a
// bit_set -- nothing to own.
//
// `mods` REUSES Modifiers rather than defining a second, mouse-shaped modifier
// set. The wire bits are a different function of a different number from
// xterm's key modifiers (see mouse_button_bits), but the VOCABULARY is the
// same three keys, and an app that wants "ctrl+click" should be able to write
// `.Ctrl in msg.mods` with the same spelling it uses for a keypress.
Mouse_Msg :: struct {
	kind:   Mouse_Kind,
	button: Mouse_Button,
	x, y:   int,
	mods:   Modifiers,
}

// Both encodings bias every byte by 32 to keep it out of the C0 range.
@(private = "file")
MOUSE_BYTE_OFFSET :: 32

@(private = "file")
mouse_is_wheel :: proc(b: Mouse_Button) -> bool {
	return b >= .Wheel_Up && b <= .Wheel_Right
}

// Cb, THE ONE BIT LAYOUT BOTH ENCODINGS SHARE. Verified against ultraviolet's
// parseMouseButton (decoder.go) rather than taken on faith:
//
//   bits 0-1  button within the current bank (see bits 6/7)
//   bit 2   4 Shift
//   bit 3   8 "meta" in xterm's own documentation -- reported as .Alt, which is
//            what every terminal actually sends for the Alt key and what the
//            reference maps it to. RuneTea's Modifiers has a separate .Meta
//            member (the 4th xterm KEY modifier bit), and deliberately does not
//            set it here: the two protocols' "meta" are not the same field, and
//            reporting .Meta for an Alt+click would be a modifier the user did
//            not press.
//   bit 4  16 Ctrl
//   bit 5  32 motion (the button, if any, is being dragged)
//   bit 6  64 WHEEL bank: 64 up, 65 down, 66 left, 67 right
//   bit 7 128 EXTRA-BUTTON bank: 128 backward, 129 forward, 130, 131
//
// With neither bank bit set, bits 0-1 are 0 left / 1 middle / 2 right / 3 "no
// button" -- and 3 is what the LEGACY encoding sends for a release, which is
// why `no_button` comes back separately instead of being folded into the
// button. SGR ignores it (its final byte carries press-vs-release); X10 needs
// it. See x10_mouse.
//
// The motion bit is NOT honoured for a wheel event: terminals set it
// spuriously on wheel reports, and a "wheel drag" is not a thing. Same rule as
// the reference's `isWheel` guard.
@(private = "file")
mouse_button_bits :: proc(cb: int) -> (button: Mouse_Button, mods: Modifiers, motion: bool, no_button: bool) {
	if cb &  4 != 0 { mods += {.Shift} }
	if cb &  8 != 0 { mods += {.Alt} }
	if cb & 16 != 0 { mods += {.Ctrl} }

	low := cb & 3
	switch {
	case cb & 128 != 0: button = Mouse_Button(int(Mouse_Button.Backward) + low)
	case cb &  64 != 0: button = Mouse_Button(int(Mouse_Button.Wheel_Up) + low)
	case low == 3:      button, no_button = .None, true
	case:               button = Mouse_Button(int(Mouse_Button.Left) + low)
	}
	if cb & 32 != 0 && !mouse_is_wheel(button) { motion = true }
	return
}

// `CSI < Cb ; Cx ; Cy M|m` -- the SGR report's parameter run, WITH its leading
// '<'.
//
// A DEDICATED PARSER, EXACTLY LIKE kitty_params, AND FOR THE SAME REASON.
// csi_params rejects the private-prefix bytes '<' '=' '>' '?' by design, and
// that rejection is load-bearing (read its comment): it is what keeps SGR
// colour, DECRPM replies and every other private-prefix sequence on the
// cleanly-ignored path instead of having their parameters silently reinterpreted
// as key parameters. So the '<' family is handled the way the 'u' family
// already was -- a separate parser reached from a specific final byte -- and
// csi_params is not widened by one byte. test_csi_params_still_rejects_colons
// and test_subparams_are_rejected_outside_csi_u both keep passing unchanged,
// and the second one now genuinely guards this parser too: `\e[<0;10:5M` has a
// ':' and must still decode to nothing.
//
// STRICTER THAN THE REFERENCE, deliberately. ultraviolet defaults a missing Cx
// or Cy to 1; here all three fields must be present and numeric, and anything
// else reports ok = false and lands on the cleanly-ignored path. A mouse report
// with a missing coordinate is not a report a terminal sends, and inventing
// column 1 for it would put a plausible-looking click at a position nothing
// clicked.
@(private = "file")
sgr_mouse :: proc(p: []u8, final: u8) -> (m: Mouse_Msg, ok: bool) {
	if len(p) < 2 || p[0] != '<' { return {}, false }
	v := [3]int{-1, -1, -1}
	n := 0
	for c in p[1:] {
		switch {
		case c >= '0' && c <= '9':
			d := int(c - '0')
			if v[n] < 0 { v[n] = 0 }
			// Bounded well above any real terminal geometry; the point is only
			// that a runaway digit run cannot overflow into a plausible value.
			if v[n] > 99999 { return {}, false }
			v[n] = v[n] * 10 + d
		case c == ';':
			n += 1
			if n >= 3 { return {}, false }   // a fourth field is not this grammar
		case:
			// ':' sub-parameters, a second private prefix, anything else.
			return {}, false
		}
	}
	if n != 2 || v[0] < 0 || v[1] < 0 || v[2] < 0 { return {}, false }

	button, mods, motion, _ := mouse_button_bits(v[0])
	m = Mouse_Msg{button = button, mods = mods, x = v[1] - 1, y = v[2] - 1}
	// One-based on the wire, zero-based in the Msg. A terminal that reports 0
	// is out of spec; clamping beats handing an application a negative index.
	if m.x < 0 { m.x = 0 }
	if m.y < 0 { m.y = 0 }
	// MOTION IS TESTED FIRST, and that is only correct because
	// mouse_button_bits has already suppressed the motion bit for a wheel event
	// (terminals set it spuriously; a "wheel drag" is not a thing). Written this
	// way round on purpose: with the wheel case first the suppression would be
	// dead code that no test could ever catch, and a redundant guard is a guard
	// nobody maintains. test_mouse_decode_table's "wheel up with the motion bit
	// set" row is the lever.
	switch {
	case motion:                 m.kind = .Motion
	case mouse_is_wheel(button): m.kind = .Wheel
	case final == 'm':           m.kind = .Release
	case:                        m.kind = .Press
	}
	return m, true
}

// `CSI M` + three RAW bytes: Cb+32, Cx+32, Cy+32. Infallible -- any three bytes
// decode to something -- because the caller has already committed to consuming
// them (see decode_keys' X10 block for why that is the only safe order).
//
// THE ASYMMETRY WITH SGR, DOCUMENTED RATHER THAN PAPERED OVER: this encoding
// CANNOT SAY WHICH BUTTON WAS RELEASED. A release is Cb bits 0-1 == 3, the same
// value the protocol uses for "no button", so the button identity is simply not
// on the wire. Such an event reports `kind = .Release, button = .None`. An app
// that needs to know which button came up must enable SGR (which term_enter_raw
// always requests) and, if the terminal ignored that request, track the last
// press itself. Faking the button by remembering the last press INSIDE the
// decoder was rejected: it would be a guess presented as a fact, and it breaks
// outright with two buttons held at once.
//
// COORDINATES PAST 223 ARE UNRECOVERABLE HERE. Cx+32 must fit in a byte, so
// column 224 encodes as byte 0 and is indistinguishable from garbage. A byte
// below 33 therefore means either an out-of-spec terminal or a wrapped
// coordinate, and neither can be turned back into the real column; it clamps to
// 0 rather than reporting a negative index. This limitation IS the reason
// term_enter_raw always asks for `?1006h`.
@(private = "file")
x10_mouse :: proc(b0, b1, b2: u8) -> Mouse_Msg {
	cb := int(b0)
	// Defensive, and copied from the reference for the same reason it is there:
	// a byte below the offset should be impossible, and underflowing into a
	// negative Cb would scramble every bit test below.
	if cb >= MOUSE_BYTE_OFFSET { cb -= MOUSE_BYTE_OFFSET }

	button, mods, motion, release := mouse_button_bits(cb)
	m := Mouse_Msg{
		button = button,
		mods   = mods,
		x      = int(b1) - MOUSE_BYTE_OFFSET - 1,
		y      = int(b2) - MOUSE_BYTE_OFFSET - 1,
	}
	if m.x < 0 { m.x = 0 }
	if m.y < 0 { m.y = 0 }
	// Motion first, for the reason spelled out in sgr_mouse.
	switch {
	case motion:                 m.kind = .Motion
	case mouse_is_wheel(button): m.kind = .Wheel
	case release:                m.kind = .Release
	}
	return m
}

// T2-B: the terminal's FOCUS events. `CSI I` says the terminal window gained
// focus, `CSI O` says it lost it.
//
// TWO ZERO-SIZED TYPES, NOT ONE Focus_Msg{focused: bool}, and the codebase
// already contains both shapes, so the choice is between two live precedents
// rather than a free one. Keyboard_Enhancements_Msg carries a VALUE because the
// value is the entire information content: there is exactly one kind of reply
// and what an app wants to know is which flags came back. Paste uses two
// zero-sized types because start and end are two DIFFERENT EVENTS that an app
// handles with two different pieces of code, and `case Paste_Start_Msg:` reads
// better than `case Paste_Msg: if msg.start`.
//
// Focus is the second shape. An app dims its UI on blur and restores it on
// focus -- two branches, never one branch parameterised by a bool -- so the
// type IS the discriminant and there is no residual value left over to carry.
// It also matches Bubble Tea's own FocusMsg/BlurMsg exactly, which is worth
// something for anyone porting an app across. Zero-sized additionally means
// box() returns a nil-data `any` and box_free no-ops, the same free ride
// Paste_Start_Msg/Paste_End_Msg and Quit_Msg already take.
Focus_Msg :: struct{}
Blur_Msg  :: struct{}

// What an out-of-band (non-Key_Msg) event is, for Input_Marker's discriminant.
//
// NOTHING HERE IS A SANE DEFAULT, so unlike Key_Kind (whose zero value Press is
// load-bearing) every construction of an Input_Marker names `kind` explicitly.
// Members are APPENDED like every other enum in this file.
Input_Marker_Kind :: enum u8 { Paste_Start, Paste_End, Mouse, Focus, Blur }

// Where a non-key event sits RELATIVE TO THE KEYS decode_keys emitted in the
// same call: the marker belongs immediately before `out[at]`, and `at ==
// len(out)` means "after everything".
//
// Positions rather than a second, unordered output stream (which is what
// `enh` is) because ORDER IS THE POINT here. An application that switches into
// a bulk-insert mode on Paste_Start_Msg needs it before the first pasted
// character, not after the last one.
//
// T2-B PUT MOUSE AND FOCUS ON THIS SAME LIST rather than giving them a stream
// of their own, and that is a correctness decision, not a tidiness one. Mouse
// ordering matters for exactly the reason paste ordering does: a user who
// clicks to place the caret and then types expects the click to land first, and
// a 1024-byte read can easily contain both (the terminal buffers while a slow
// frame renders). The keyboard-enhancement reply is the genuine exception --
// it arrives once, in answer to a query written before any key can be pressed,
// so it has no ordering requirement and stays on `enh`.
//
// TWO POSITIONED STREAMS WOULD HAVE HAD AN UNRESOLVABLE TIE. `\e[<0;1;1M\e[200~`
// puts a mouse click and a paste start both at `at == 0`, and with the two on
// separate lists nothing in either one records which came first on the wire.
// One list keeps them in decode order by construction, which is why the paste
// marker type was generalised instead of duplicated.
//
// `mouse` is meaningful only when `kind == .Mouse`; it is zero for every other
// kind, which keeps Input_Marker comparable with == in tests.
Input_Marker :: struct {
	at:    int,
	kind:  Input_Marker_Kind,
	mouse: Mouse_Msg,
}

// decode_keys' cross-call state AND its non-key output, in one struct because a
// caller needs both or neither.
//
// `in_paste` is DECODER STATE THAT MUST PERSIST ACROSS CALLS. The reader calls
// decode_keys once per read(), and a paste of any size straddles reads, so
// "am I inside a paste?" cannot live in a local. It is not a package-level
// global either: there is more than one decoder in this process (run() and
// run_nbio() each own a reader, and tests call decode_keys directly), and a
// shared global would have one reader's paste swallow another's keystrokes.
// The caller owns the struct; both event-loop hosts keep one next to their
// `pending` buffer.
//
// Mouse and focus need no such state -- each of their sequences is
// self-contained -- so they contribute output here and nothing else.
//
// `markers` is CALLER-CLEARED, exactly like `out` and `enh`: decode_keys only
// appends. Delete it when done -- it is the one allocation this type owns.
Input_State :: struct {
	in_paste: bool,
	markers:  [dynamic]Input_Marker,
}

// Boxes an Input_Marker as the Msg it denotes. Package-visible because both
// event-loop hosts need it and Odin has no closures to share the branch with;
// context.allocator (never the frame arena) because these cross a thread
// boundary into the mailbox like every other Msg -- see arena.odin's LIFETIME
// CONTRACT. Four of the five kinds are zero-sized, so box() returns a nil-data
// `any` and box_free no-ops on them, exactly as it already does for Quit_Msg;
// Mouse_Msg is a real (POD) allocation like Key_Msg.
@(private = "package")
input_marker_box :: proc(m: Input_Marker) -> any {
	switch m.kind {
	case .Paste_Start: return box(Paste_Start_Msg{}, context.allocator)
	case .Paste_End:   return box(Paste_End_Msg{}, context.allocator)
	case .Mouse:       return box(m.mouse, context.allocator)
	case .Focus:       return box(Focus_Msg{}, context.allocator)
	case .Blur:        return box(Blur_Msg{}, context.allocator)
	}
	// Unreachable: the switch above is exhaustive over Input_Marker_Kind. Odin
	// still needs a terminating return, and a nil `any` here would at least fail
	// loudly at the first type switch rather than pretending to be some Msg.
	return nil
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
//
// NARROWED SINCE: 0x80-0x9F NO LONGER REACHES THIS PROC. Treating that band as
// stray continuation bytes was the conflation behind the 8-bit C1 leak -- 0x9B
// is CSI, not a broken rune, and answering U+FFFD for it left the whole
// sequence body to be typed in as keystrokes. decode_keys' introducer gate now
// claims 0x80-0x9F before the UTF-8 path is reached. The sentence above still
// describes 0xA0-0xBF exactly, which is the part of the range that really is
// nothing but a continuation byte out of place.
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
// THIS IS NOT THE KITTY BITMASK -- see kitty_mods, which is a different
// function of the same-shaped number. Bit 8 here is Meta (xterm's meaning);
// bit 8 in Kitty is Super and Meta moves to bit 32. Sharing one proc between
// the two encodings would mis-name a modifier on every Kitty event that has
// one, which is precisely why there are two.
//
// BITS ABOVE 8 USED TO BE MASKED OFF, and this is where LIMITATIONS 5.7's
// "CSI 1;33A decodes as plain Up" came from. They are decoded now, using
// KITTY'S table for exactly the bits where the two encodings cannot disagree:
//
//   bit  16  32  64  128
//        Hyper Meta Caps Num      (Kitty)
//        --unused, all four--     (xterm)
//
// xterm's table stops at bit 8, so no terminal driving THIS proc under xterm's
// rules can ever set one of them. A set bit up there is therefore proof the
// terminal is speaking Kitty's table, and decoding it can only add information
// that was previously thrown away -- it cannot mis-name anything, because there
// is no competing meaning to mis-name it as.
//
// BIT 8 IS THE ONE PLACE THAT ARGUMENT DOES NOT HOLD, and it stays Meta. xterm
// says Meta, Kitty says Super, both send it in this same sequence shape, and
// nothing in the bytes distinguishes them. Meta is kept because it is what this
// proc has always answered, what xterm -- the encoding this proc is named for
// -- defines, and what the existing tests pin. The consequence, stated rather
// than hidden: a Super-modified arrow key from a Kitty-protocol terminal that
// chose the legacy sequence shape reports as {.Meta}. An application that wants
// an unambiguous Super binding should enable the Kitty keyboard protocol, where
// kitty_mods reads the same bit correctly.
xterm_mods :: proc(param: int) -> (mods: Modifiers, ok: bool) {
	if param < 1 || param > 256 { return {}, false }
	mask := param - 1
	if mask &   1 != 0 { mods += {.Shift} }
	if mask &   2 != 0 { mods += {.Alt} }
	if mask &   4 != 0 { mods += {.Ctrl} }
	if mask &   8 != 0 { mods += {.Meta} }
	if mask &  16 != 0 { mods += {.Hyper} }
	if mask &  32 != 0 { mods += {.Meta} }
	if mask &  64 != 0 { mods += {.Caps_Lock} }
	if mask & 128 != 0 { mods += {.Num_Lock} }
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
//
// `mods` IS THE MODIFIER THE FINAL BYTE ITSELF IMPLIES, which is empty for
// every entry but one. 'Z' (CBT, "cursor backward tabulation") is Shift+Tab and
// nothing else -- the shift is in the final byte, not in a parameter -- so it is
// the only sequence in this grammar whose modifier cannot come from
// xterm_mods. The caller UNIONS this with whatever an explicit `;<mod>`
// parameter carried, which is what makes `CSI 1;5Z` (Ctrl+Shift+Tab) come out
// with both rather than losing the shift.
//
// SHIFT+TAB WAS A REAL GAP, not a completeness exercise: `kcbt=\E[Z` is present
// in 21 of the 40 terminfo entries on this machine, including xterm,
// xterm-256color, tmux, tmux-256color, screen, rxvt and rxvt-unicode, and
// "previous field" is a standard binding in every form-shaped TUI. It is also
// what the Kitty protocol already produced here (CSI 9;2u -> Tab + {.Shift},
// see kitty_key_code), so before this the same keypress decoded to a key under
// Kitty and to nothing at all without it.
csi_letter_code :: proc(final: u8) -> (code: Key_Code, mods: Modifiers, ok: bool) {
	switch final {
	case 'A': return .Up, {}, true
	case 'B': return .Down, {}, true
	case 'C': return .Right, {}, true
	case 'D': return .Left, {}, true
	case 'F': return .End, {}, true
	case 'H': return .Home, {}, true
	case 'P': return .F1, {}, true
	case 'Q': return .F2, {}, true
	case 'R': return .F3, {}, true
	case 'S': return .F4, {}, true
	case 'Z': return .Tab, {.Shift}, true   // CBT -- Shift+Tab
	}
	return .Rune, {}, false
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
// The Kitty keyboard protocol's full eight-bit modifier table, all of it. The
// four this used to drop -- Super (8), Hyper (16), Caps Lock (64) and Num Lock
// (128) -- are LIMITATIONS 5.7's other half: Kitty's Ctrl+Super+a arrived as a
// plain Ctrl+a, because bit 8 had nowhere to go.
//
// Bit 8 is SUPER here and Meta here is bit 32. That is not a typo and not a
// disagreement with xterm_mods above; it is the protocols themselves
// disagreeing, which is why these are two procs and not one with a flag.
kitty_mods :: proc(param: int) -> (mods: Modifiers, ok: bool) {
	if param < 1 || param > 256 { return {}, false }
	mask := param - 1
	if mask &   1 != 0 { mods += {.Shift} }
	if mask &   2 != 0 { mods += {.Alt} }
	if mask &   4 != 0 { mods += {.Ctrl} }
	if mask &   8 != 0 { mods += {.Super} }
	if mask &  16 != 0 { mods += {.Hyper} }
	if mask &  32 != 0 { mods += {.Meta} }
	if mask &  64 != 0 { mods += {.Caps_Lock} }
	if mask & 128 != 0 { mods += {.Num_Lock} }
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

// The codepoints of a Kitty associated-text field AFTER the first, which the
// key's own Key_Msg.r already carries. Returned alongside the key rather than
// stored on it -- see kitty_decode's field-2 comment for why the tail becomes
// extra Key_Msgs instead of a field every application would have to learn
// about. Plain POD, returned by value, never allocated: `n` is 0 for every
// sequence that is not a multi-codepoint Kitty text event, which is all of
// them except IME and dead-key composition.
Key_Text_Tail :: struct {
	r: [KITTY_MAX_SUBS - 1]rune,
	n: int,
}

// Appends a decoded key and whatever associated-text codepoints followed it.
// One proc rather than two open-coded loops so the two csi_decode call sites
// below cannot drift on what a tail means.
append_key :: proc(out: ^[dynamic]Key_Msg, key: Key_Msg, tail: Key_Text_Tail) {
	append(out, key)
	for i in 0 ..< tail.n {
		// Deliberately bare: no modifiers, no kind, and NOT marked `pasted`
		// (this is typed text, not a paste, and an application filtering on
		// `pasted` is asking a different question).
		append(out, Key_Msg{code = .Rune, r = tail.r[i]})
	}
}

// Kitty's parameter grid: up to KITTY_MAX_FIELDS ';'-separated fields, each
// with ':'-separated sub-parameters. Values are -1 when the slot is present but
// empty ("\e[97;;98u" has an empty modifier field), which is NOT the same as 0.
//
// `nsub` counts sub-parameters even past what `v` can store, because the text
// field's COUNT is what decides whether it is usable (see kitty_decode).
KITTY_MAX_FIELDS :: 3
// Was 3, which was enough for fields 0 and 1 (they define three sub-parameters
// each and no more) but not for field 2, the ASSOCIATED TEXT, whose length the
// protocol does not bound. 8 covers what a keyboard actually produces: a dead
// key or IME commit is one to three codepoints, and the longest realistic case
// is a ZWJ emoji sequence. Text longer than this is truncated to the first 8
// codepoints rather than dropped whole, which is the same trade the rest of
// this decoder makes -- see kitty_decode.
KITTY_MAX_SUBS   :: 8

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
kitty_decode :: proc(p: []u8) -> (key: Key_Msg, tail: Key_Text_Tail, ok: bool) {
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

	// Field 2: the ASSOCIATED TEXT. Only overrides a .Rune key: a functional
	// key's text field (if a terminal ever sent one) has no rune to override.
	//
	// EVERY CODEPOINT IS EMITTED, NOT JUST THE FIRST (LIMITATIONS 5.8). The
	// guard here used to be `kp.nsub[2] == 1`, so a text field with more than
	// one codepoint -- which is exactly what IME composition and dead-key
	// sequences produce -- failed the test and the whole field was dropped: the
	// user typed `é` and the application received the raw key with no text at
	// all. That was the single largest correctness gap left in this decoder for
	// anyone typing a language that needs composition.
	//
	// WHY EXTRA Key_Msgs RATHER THAN A MULTI-RUNE FIELD ON Key_Msg, which is
	// what 5.8 assumed the fix would be. A `text: [8]rune` field would be
	// POD-safe and would work, but every application would have to learn about
	// it: `case .Rune: insert_rune(k.r)` -- the shape every example, the README
	// and docs/API.md all teach -- would still insert only the first codepoint,
	// so the bug would move from the decoder into every program written against
	// it. Emitting the tail as ordinary .Rune presses instead means an
	// application that already handles typing handles composition too, with no
	// edit. It is also not a new idea here: bracketed paste already delivers its
	// content as ordinary keypresses for precisely this reason (Key_Msg.pasted).
	//
	// THE TAIL CARRIES NO MODIFIERS AND NO EVENT KIND, deliberately, and again
	// this follows paste. Composed text is TEXT; the Shift that produced the
	// dead key is a property of the keystroke, not of each codepoint it
	// committed. The first Key_Msg keeps the full key semantics so a binding on
	// it still matches.
	if kp.nfield >= 3 && kp.nsub[2] >= 1 && key.code == .Rune && kitty_printable(kp.v[2][0]) {
		key.r = rune(kp.v[2][0])
		n := min(kp.nsub[2], KITTY_MAX_SUBS)
		for s in 1 ..< n {
			if !kitty_printable(kp.v[2][s]) { break }
			tail.r[tail.n] = rune(kp.v[2][s])
			tail.n += 1
		}
	}
	return key, tail, true
}

// Decodes one COMPLETE CSI whose parameter bytes are `p` and whose final byte
// is `final`. `has_intermed` says whether any intermediate byte (0x20-0x2F)
// was present; every key form this decoder knows has none, so an intermediate
// byte is an immediate "not a key" (it is DECRPM, urxvt's CSI <n> $, ...).
//
// ok = false means "complete, but not a key this decoder understands" -- the
// caller consumes the sequence and emits nothing. It never means "incomplete";
// incompleteness is decided by the caller before this proc is reached.
csi_decode :: proc(p: []u8, has_intermed: bool, final: u8, legacy: Legacy_Key_Encoding) -> (key: Key_Msg, tail: Key_Text_Tail, ok: bool) {
	if has_intermed { return {}, {}, false }

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
		// XTERM'S modifyOtherKeys REPORT: CSI 27 ; <mod> ; <codepoint> ~.
		//
		// This is a THREE-parameter tilde sequence, and it used to be rejected
		// twice over: by the `count > 2` gate immediately below, and -- had that
		// been widened alone -- by csi_tilde_code, whose table lists 27 as
		// unassigned and returns ok = false for it. Hence the special case HERE,
		// ahead of both, rather than a new row in that table: 27 is not a tilde
		// key id at all, it is a marker saying "the real key is in parameter 3".
		//
		// WHY IT MATTERS DESPITE BEING NON-DEFAULT. Alongside the Kitty protocol
		// this is the only legacy mechanism that resolves the Ctrl+I/Tab and
		// Ctrl+M/Enter collisions Legacy_Key documents, and the only one that
		// delivers Ctrl+digit and Ctrl+punctuation at all -- input.odin's
		// Legacy_Key comment already names it as such. It is NOT common: xterm's
		// modifyOtherKeys resource defaults to 0 and tmux's
		// extended-keys-format defaults to `csi-u` (the Kitty shape decoded
		// above), so these bytes arrive only where a user has explicitly turned
		// modifyOtherKeys on, or set extended-keys-format=xterm, on a terminal
		// with no Kitty support. Decoding it costs five lines and turns a
		// deliberately-configured terminal from "silently drops the key" into
		// "reports it", which is worth those lines.
		//
		// kitty_key_code is reused rather than re-tabulated because the payload
		// IS a Unicode key code in exactly Kitty's sense -- 9 is Tab, 13 Enter,
		// 49 is '1' -- so a second table could only drift from the first. The
		// modifier field is xterm's (1 + bitmask), NOT Kitty's, hence
		// xterm_mods; see its comment for why the two must not be shared.
		if count == 3 && params[0] == 27 {
			mods := xterm_mods(params[1]) or_return
			key  := kitty_key_code(params[2]) or_return
			key.kind  = kind
			key.mods += mods
			return key, {}, true
		}
		if count == 0 || count > 2 { return {}, {}, false }
		code := csi_tilde_code(params[0], legacy) or_return
		if count == 1 { return Key_Msg{kind = kind, code = code}, {}, true }
		mods := xterm_mods(params[1]) or_return
		return Key_Msg{kind = kind, code = code, mods = mods}, {}, true
	}

	// URXVT'S MODIFIED TILDE KEYS: the modifier rides in the FINAL BYTE, not in
	// a parameter. `CSI 3 $` is Shift+Delete, `CSI 3 ^` is Ctrl+Delete, `CSI 3 @`
	// is Ctrl+Shift+Delete -- the parameter is the same tilde key id csi_tilde_code
	// already knows, which is why this is three lines and not a table.
	//
	// rxvt-unicode is the second of the two terminals whose key table the xterm
	// defaults measurably do NOT cover (25/71 capabilities; see the terminfo
	// note in decode_keys' comment), and this is the larger half of that miss:
	// kDC/kIC/kHOM/kEND/kNXT/kPRV and their Ctrl forms, i.e. Shift+Delete,
	// Shift+Insert, Shift+Home, Shift+End, Shift+PgDn, Shift+PgUp and the same
	// six with Ctrl. All twelve used to be cleanly ignored at best -- and the
	// '$' six were worse than ignored, see decode_keys' '$' arm.
	//
	// '^' (0x5E) and '@' (0x40) are ordinary CSI final bytes and reach here by
	// the normal route. '$' (0x24) is an INTERMEDIATE byte under the ECMA-48
	// grammar and cannot; decode_keys claims it before the intermediate scan and
	// calls in here with has_intermed = false, which is why this arm sits below
	// the `has_intermed` rejection at the top rather than being exempted from it.
	if final == '$' || final == '^' || final == '@' {
		if count != 1 { return {}, {}, false }
		code := csi_tilde_code(params[0], legacy) or_return
		mods: Modifiers
		switch final {
		case '$': mods = {.Shift}
		case '^': mods = {.Ctrl}
		case '@': mods = {.Ctrl, .Shift}
		}
		return Key_Msg{kind = kind, code = code, mods = mods}, {}, true
	}

	code, base := csi_letter_code(final) or_return
	if count == 0 { return Key_Msg{kind = kind, code = code, mods = base}, {}, true }
	if count > 2 { return {}, {}, false }
	// The first parameter of a modified cursor/function key is always 1 (the
	// "one key" repeat count); anything else is a different sequence that
	// happens to share our final byte -- a cursor position report, most
	// importantly -- and must not be decoded as a key.
	id := params[0]
	if id < 0 { id = 1 }
	if id != 1 { return {}, {}, false }
	if count == 1 { return Key_Msg{kind = kind, code = code, mods = base}, {}, true }
	mods := xterm_mods(params[1]) or_return
	return Key_Msg{kind = kind, code = code, mods = mods + base}, {}, true
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

// Is this parameter run a bare decimal number -- no private prefix, no ';', no
// ':', not empty? Used by decode_keys' urxvt '$' arm and by nothing else.
//
// It exists to keep that arm from stealing DECRPM. A DECRQM reply is
// `CSI ? <mode> ; <value> $ y`: its '$' is a genuine ECMA-48 intermediate byte
// followed by the final 'y', and terminating the sequence AT the '$' would drop
// the 'y' back into the stream as a literal rune -- reintroducing, on a
// different sequence, exactly the leak the '$' arm exists to remove. Every real
// DECRPM reply carries a '?' prefix and two parameters, so requiring a bare
// number excludes all of them; urxvt's forms are always a single bare digit.
@(private = "file")
csi_bare_number :: proc(p: []u8) -> bool {
	if len(p) == 0 { return false }
	for c in p {
		if c < '0' || c > '9' { return false }
	}
	return true
}

// Where a STRING ESCAPE (OSC, DCS, APC, PM, SOS) ends, given the index of the
// first byte of its payload. ok = false means "the terminator has not arrived
// yet" -- hold back, exactly as a half-arrived CSI does.
//
// THIS EXISTS BECAUSE THE ABSENCE OF IT WAS THE WORST INPUT BUG IN THE FILE.
// decode_keys used to dispatch on '[' (CSI), 'O' (SS3) and a second ESC, and
// send everything else down the Alt+key path. So an OSC arriving on the input
// stream -- a `CSI 11 t`-style background-colour reply, an OSC 52 clipboard
// read, a DCS/XTVERSION reply, a Kitty graphics APC ack, any of which the shell
// or a previous program can leave in flight -- was not "a sequence we do not
// understand, cleanly ignored". It was TYPED INTO THE APPLICATION: the
// introducer became Alt+']' / Alt+'P' / Alt+'_', the payload became one Key_Msg
// per byte, a BEL terminator became Ctrl+G and an ST terminator became Alt+'\'.
// MEASURED against the pre-fix decoder: one xterm OSC 11 reply
// (`\e]11;rgb:2e2e/3434/3a3a\e\\`) produced 23 spurious Key_Msgs -- Alt+']', then
// the 21 payload characters one at a time, then Alt+'\\'. The BEL-terminated
// spelling of the same reply produced 23 too, ending in Ctrl+G. So two
// modifier-bearing keypresses per reply, i.e. two chances to fire a keybinding,
// plus 21 characters inserted into whatever had focus.
//
// TERMINATORS, and why each is here:
//   - ST in both spellings, ESC '\' (7-bit) and 0x9C (8-bit). The defined
//     terminator for all five string types;
//   - BEL, for OSC ONLY. xterm has accepted BEL as an OSC terminator since
//     forever and most terminals still emit it, but nothing terminates a DCS or
//     an APC with BEL, and accepting it everywhere would cut a DCS payload short
//     at the first 0x07 byte in it -- which for a binary DCS/APC payload (Kitty
//     graphics) is a realistic byte, and cutting short is how the tail becomes
//     keystrokes again;
//   - CAN (0x18) and SUB (0x1A), ECMA-48's cancel-the-control-string bytes.
//     Cheap, standard, and the only bounded way out of a string a terminal began
//     and then abandoned;
//   - an ESC that is NOT followed by '\'. Per xterm's parser an ESC inside a
//     string aborts it, and the abort is the useful reading here: it hands the
//     ESC back to the main loop so a real key sequence arriving after a
//     malformed string still decodes, instead of being eaten as payload.
//
// AN UNTERMINATED STRING STALLS THE DECODER, and that is accepted rather than
// bounded. The alternative -- cap the payload at N bytes, then consume and drop
// -- was rejected: past the cap the REST of the payload lands back in the stream
// as keystrokes, which is the precise failure this proc removes, and no cap can
// be right for both an 8-byte OSC 11 reply and a multi-kilobyte OSC 52 clipboard
// read. So it holds back, bounded only by the terminal's own good behaviour, on
// the same terms `CSI M` already stalls on three missing payload bytes (see the
// X10 mouse block in decode_keys). The four cancel bytes above mean a terminal
// that abandons a string mid-flight -- as opposed to one that never terminates
// it at all -- costs nothing.
@(private = "file")
string_escape_end :: proc(data: []u8, from: int, bel_terminates: bool) -> (end: int, ok: bool) {
	k := from
	for k < len(data) {
		switch data[k] {
		case 0x07:
			if bel_terminates { return k + 1, true }
		case 0x9c:
			return k + 1, true                          // 8-bit ST
		case 0x18, 0x1a:
			return k + 1, true                          // CAN / SUB: cancelled
		case 0x1b:
			if k + 1 >= len(data) { return 0, false }   // ESC '\'? not enough bytes to say
			if data[k + 1] == '\\' { return k + 2, true }
			return k, true                              // aborts the string, ESC stays
		}
		k += 1
	}
	return 0, false
}

// Decodes as many complete keys as `data` contains, appending to `out`.
// Returns the number of bytes consumed; a trailing partial escape sequence
// or a trailing partial UTF-8 rune is left unconsumed so the caller can
// retry once more bytes arrive.
//
// Vocabulary: printable runes; C0 control bytes per decode_c0's policy;
// Enter/Tab/Space/Backspace/Escape; ESC + any C0 byte or DEL as Alt + that same
// key, through the same policy; arrows, Home, End, Page_Up, Page_Down,
// Insert, Delete and F1-F12 in their CSI-tilde, CSI-letter and SS3 encodings;
// xterm modifier parameters (Shift/Alt/Ctrl/Meta) on all of those; xterm's
// modifyOtherKeys report (CSI 27 ; <mod> ; <codepoint> ~); urxvt's modified
// tilde keys, where the modifier is the final byte (CSI 3 $ / ^ / @); the Linux
// virtual console's F1-F5 (CSI [ A .. CSI [ E); the
// Kitty keyboard protocol's CSI-u key events, including press/repeat/release
// event types and the alternate-key and text sub-parameter forms; Kitty's
// event-type sub-parameter on the LEGACY encodings (CSI 1;5:3 A,
// CSI 3;5:3 ~); bracketed paste (CSI 200~ ... CSI 201~), whose content is
// streamed as Key_Msgs with `pasted = true` and whose boundaries land in
// `st.markers`; mouse reports in BOTH encodings (SGR CSI < Cb;Cx;Cy M/m and
// legacy CSI M + three raw bytes) and focus in/out (CSI I / CSI O), which land
// in `st.markers` too; and the terminal's keyboard-enhancement reply
// (CSI ? <flags> u), which is the one thing here that is not a Key_Msg and so
// goes to `enh` instead of `out`.
//
// EVERY GRAMMAR ABOVE IS ACCEPTED IN BOTH ITS 7-BIT AND ITS 8-BIT SPELLING
// (ESC [ or 0x9B, ESC O or 0x8F, ...) -- see the introducer gate inside this
// proc -- with ONE deliberate exception: bracketed paste is matched on its full
// 7-bit byte string, so an 8-bit `0x9B 200~` is cleanly ignored rather than
// opening a paste. That asymmetry is on purpose. Recognising the 8-bit START
// without also recognising the 8-bit END would wedge the decoder in paste mode
// for the rest of the session -- the worst failure in this file -- and the END
// is matched inside the paste branch, against a byte string, precisely so a
// still-arriving terminator can be compared to a prefix of itself.
//
// The five STRING ESCAPES (OSC ']', DCS 'P', SOS 'X', PM '^', APC '_') are
// parsed but not decoded: consumed whole to their terminator, emitting nothing.
// See string_escape_end for why they cannot simply be left to the Alt+key path.
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
// The state lives in `st` (see Input_State) because the reader calls this
// proc once per read and a paste of any size straddles reads. With st == nil
// paste is still decoded WITHIN a single buffer, but the mode cannot survive
// the call and the markers have nowhere to go -- the same degradation
// enh == nil gives the enhancement reply, and the same one mouse and focus
// events get (still consumed whole, just dropped).
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
// leaking bytes as garbage runes.
//
// THAT SECOND CLAUSE WAS FALSE FOR TWO OF THE ENTRIES THAT USED TO BE ON THIS
// LIST, and the list said so about one of them three lines into its own bullet
// ("the '[' is a final byte and the letter is left over"). The Linux console's
// F1-F5 leaked a capital letter per keypress; rxvt's '$'-final keys leaked
// their parameter and their '$' as two runes, or ate the following keystroke.
// Both are decoded outright now rather than merely swallowed, so the header is
// true as stated -- and there is a test for it, which there was not before:
// test_linux_console_function_keys_decode,
// test_urxvt_dollar_keys_do_not_eat_the_next_keystroke and
// test_a_csi_ending_on_an_intermediate_is_consumed_not_leaked. The claim is
// worth stating carefully because a decoder's promise not to type at the user
// is only as good as the population it was checked over:
//   - the urxvt (CSI 1015) and SGR-PIXEL (CSI 1016) mouse encodings.
//     term_enter_raw never asks for either, so a terminal never sends one
//     unbidden; urxvt's `CSI <Cb> ; <Cx> ; <Cy> M` has no private prefix and
//     would need a way to tell it from a key sequence, and SGR-pixel reports
//     PIXEL coordinates, which Mouse_Msg (documented as cell coordinates)
//     cannot carry without a unit field;
//   - DECSET 9 (X10 press-only tracking). Mouse_Mode has no member for it: it
//     reports presses and never releases, which makes drag and click-release
//     UIs silently impossible, and every terminal that supports it supports
//     1000 as well;
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
//   - keypad/DECKPAM keys (ESC O M/X/j-y, ESC O w/x/y/q/s/t/u/v/r for the
//     numeric block, ESC O M for keypad Enter) and Begin (CSI E / ESC O E);
//   - rxvt's lowercase-letter arrow forms (CSI a/b/c/d). Its '$'-final shifted
//     keys USED TO BE on this list and were the reason the list's own header
//     was false: '$' is an intermediate byte, so the scan waited for a final
//     and ate the user's next keystroke. They are decoded now -- see the '$'
//     arm below and csi_decode's urxvt block;
//   - F13-F20 (CSI 25~ and up), which Key_Code does not carry;
//   - terminfo. The tables here are the xterm/VT220 defaults, not the
//     terminal's own key table; a terminal that reports something else is a
//     terminal this decoder does not fully understand. MEASURED, not asserted:
//     against every terminfo entry installed on this machine, the xterm
//     defaults decode 136/157 capabilities for xterm and xterm-256color,
//     136/138 for tmux and tmux-256color, and 23/25 for screen -- the misses
//     being exactly the keypad block, F13-F20 and `kmous` (which is the mouse
//     capability, decoded elsewhere). They decode 20/36 for the Linux console
//     and 25/71 for rxvt-unicode. So "xterm defaults cover the common
//     terminals" holds for the terminals people actually use, and does NOT hold
//     in general for the Linux console or for rxvt -- though the two specific
//     misses that used to LEAK (Linux F1-F5, rxvt's '$' keys) are decoded now,
//     so what is left on those two terminals is silence, not typing. See
//     docs/LIMITATIONS.md.
//   - cursor position reports. CSI <row>;<col> R and modified-F3
//     (CSI 1;<mod> R) are the same bytes when row == 1, and this decoder
//     resolves them as F3 because RuneTea never issues a DSR 6n. If that ever
//     changes, this is the collision to revisit; ultraviolet handles it by
//     emitting BOTH events, which needs a Msg vocabulary we do not have yet.
//
// HOLD-BACK CONTRACT (the subtle part): a sequence that is still arriving --
// "\e" alone at the very end of the buffer, "\e[" with nothing after it, a
// CSI whose final byte (0x40-0x7E) hasn't arrived yet, an SS3 whose GL byte
// hasn't arrived yet, an OSC/DCS/APC/PM/SOS whose terminator hasn't arrived
// yet, a bare 8-bit introducer (0x9B, 0x8F, 0x90, ...) with nothing after it,
// or a UTF-8 lead byte without all of its continuation
// bytes yet, or a legacy mouse report whose three RAW bytes have not all
// landed -- must NOT be decoded yet. Emitting a spurious Escape, or a
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
// C0 gate below, at the Alt+C0 gate on the ESC path, and at the plain-C1 gate;
// it reaches csi_decode for CSI 1~/4~. Ctrl_Open_Bracket is the odd one
// out: ESC is intercepted HERE, above the C0 gate, because it also introduces
// sequences. So the flag applies at exactly the two points where an Escape is
// RESOLVED -- the lone-ESC-at-end-of-buffer case and the double-ESC case, both
// of which call decode_c0(0x1b, legacy) instead of building a Key_Msg inline,
// so there is one answer, not three. It must NOT touch the hold-back decisions
// or the ESC [ / ESC O grammars: where a sequence ends is
// decided by the BYTES, and renaming a resolved Escape cannot change that.
//
// THIS USED TO SAY "or the Alt+key path", and that was a description of a bug,
// not a rule. The Alt path never called decode_c0 at all, so ESC + 0x0D came
// out as a raw CR rune rather than as Enter+{.Alt} and no legacy flag could
// reach it. It calls decode_c0 now, so Alt+Enter with .Ctrl_M set is
// Ctrl+Alt+m, exactly as bare Enter with .Ctrl_M set is Ctrl+m. Ctrl_Open_
// Bracket is still excluded from it -- and structurally, not by a special case:
// a second ESC is claimed by the double-Escape arm before the Alt+C0 gate can
// see it, so the byte handed to decode_c0 there is never 0x1b.
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
	st:     ^Input_State = nil,
) -> (consumed: int) {
	// Mirrored into a local and written back on EVERY exit path (there are
	// several early returns for hold-back). With st == nil the local is the
	// only state there is, which is what makes paste work within one buffer
	// but not across calls -- see this proc's doc comment.
	in_paste := st != nil && st.in_paste
	defer { if st != nil { st.in_paste = in_paste } }

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
					if st != nil { append(&st.markers, Input_Marker{at = len(out), kind = .Paste_End}) }
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

		// THE INTRODUCER GATE, 7-bit and 8-bit resolved into one pair of values.
		//
		// Every grammar below is introduced either by "ESC <c>" (7-bit) or by a
		// single C1 byte in 0x80-0x9F (8-bit): 0x9B is CSI, 0x8F is SS3, 0x90 is
		// DCS, 0x9D/0x9E/0x9F are OSC/PM/APC, 0x98 is SOS. The two spellings
		// differ ONLY in how many bytes the introducer costs, so they are
		// normalised here into (`intro`, the 7-bit introducer character; `body`,
		// the index of the first byte after it) and every arm is written against
		// that pair. The C1 byte maps to its 7-bit character by subtracting 0x40,
		// which is what "C1 equivalent" means: 0x9B - 0x40 == '['.
		//
		// BEFORE THIS, 0x80-0x9F HAD NO CASE AT ALL. The dispatch went ESC, then
		// the C0 gate, then straight to the UTF-8 path -- where utf8_lead_len
		// reports 1 for every byte in 0x80-0xBF and decode_rune substitutes
		// U+FFFD. So `0x9B A` (8-bit CSI Up, what a terminal in S8C1T mode sends)
		// came out as U+FFFD followed by a literal 'A', and a whole 8-bit OSC
		// leaked its entire payload as runes. The comment on utf8_lead_len still
		// stands for 0xA0-0xBF -- those really are stray continuation bytes with
		// nothing to hold back for -- but conflating C1 with them was the bug.
		//
		// A C1 BYTE THAT IS NOT AN INTRODUCER is xterm's eightBitInput meta
		// encoding: with that resource on and UTF-8 off, Alt+Ctrl+A arrives as
		// 0x81 rather than as `ESC 0x01`. It is decoded at the bottom of this
		// block as Alt + whatever decode_c0 makes of `b - 0x80`, which gives
		// Ctrl+Alt+a for 0x81 and is byte-for-byte the same Key_Msg the 7-bit
		// spelling now produces. ultraviolet (decoder.go) reaches the same answer
		// by a different route -- rune(b)-0x40 with ModCtrl|ModAlt, i.e. an
		// UPPERCASE 'A' -- which would be inconsistent with this decoder's own C0
		// policy, where every Ctrl+letter is lowercase; decode_c0 is reused
		// precisely so there is one answer to "what is Ctrl+A" and not two.
		//
		// THE COST, stated plainly: a terminal that is not speaking UTF-8 and
		// sends Latin-1 text now reports 0x80-0x9F as keypresses instead of as
		// U+FFFD. Both readings are wrong for that terminal; the C1 one is at
		// least the standard one, and the range is unassigned in Latin-1 anyway.
		intro: u8 = 0
		body := 0
		switch {
		case b == 0x1b:
			if i + 1 >= len(data) {
				// Lone ESC at the very end of the buffer. Ambiguous: it may be a
				// real Escape or the start of a sequence still in flight. The
				// spike resolves it as Escape; a timer-based disambiguation is
				// T1 work (spec §12).
				append(out, decode_c0(0x1b, legacy))
				return i + 1
			}
			intro, body = data[i + 1], i + 2
		case b >= 0x80 && b <= 0x9f:
			intro, body = b - 0x40, i + 1
		}

		// `body != 0` is the "an introducer was resolved" test, and it is exact:
		// the switch above leaves body at 0 for every other byte, and sets it to
		// i+1 or i+2 -- never 0 -- for the two that introduce something. Testing
		// `intro != 0` instead would be WRONG: `ESC NUL` is a real (if silly)
		// keypress whose intro byte IS 0, and it belongs on the Alt path below.
		if body != 0 {
			if intro == '[' {
				// CSI grammar: ESC [ <parameter bytes 0x30-0x3F>*
				//                    <intermediate bytes 0x20-0x2F>*
				//                    <final byte 0x40-0x7E>
				// Scan to the final byte first, WITHOUT interpreting any
				// parameters: that is what decides where the sequence ends,
				// and therefore whether to hold it back at all. Only once the
				// whole sequence is in hand does csi_decode get to say what it
				// means -- so "not a key we know" and "not here yet" can never
				// be confused for each other.
				ps := body
				// THE LINUX VIRTUAL CONSOLE'S F1-F5: `ESC [ [ A` .. `ESC [ [ E`.
				//
				// Claimed here, ahead of the parameter scan, because under the
				// CSI grammar it is not one sequence but one-and-a-bit: '[' is
				// 0x5B, a perfectly legal FINAL byte, so the scan below used to
				// stop on it, hand `ESC [ [` to csi_decode (which knows no key
				// with a '[' final), consume three bytes -- and leave the letter
				// behind, where the plain-rune path at the bottom of this loop
				// typed it into the application. Pressing F1 on a bare TTY
				// inserted a capital 'A'. That made this decoder's standing
				// promise ("an unsupported sequence is consumed whole and emits
				// nothing, never leaked as garbage runes") false for one of the
				// exact two populations the limitation list itself named.
				//
				// Decoding them outright rather than merely swallowing them costs
				// two lines more and removes a documented gap: the Linux console
				// is the terminal the xterm defaults cover worst (20/36 terminfo
				// capabilities), and F6-F12 there already decode via the standard
				// tilde forms, so F1-F5 were the hole.
				//
				// A letter outside A-E is consumed and ignored -- there is no
				// such Linux-console key, and the point of the arm is that
				// nothing after `ESC [ [` ever reaches the rune path again.
				if ps < len(data) && data[ps] == '[' {
					if ps + 1 >= len(data) { return i }   // the letter has not arrived: hold back
					if c := data[ps + 1]; c >= 'A' && c <= 'E' {
						// Contiguous by construction -- see Key_Code's comment on
						// why the F-block's order is load-bearing.
						append(out, Key_Msg{code = Key_Code(int(Key_Code.F1) + int(c - 'A'))})
					}
					i = ps + 2
					continue
				}
				j  := ps
				for j < len(data) && data[j] >= 0x30 && data[j] <= 0x3F { j += 1 }
				pe := j
				// URXVT'S '$'-FINAL MODIFIED KEYS, claimed before the
				// intermediate scan because that scan is what used to eat them.
				//
				// '$' is 0x24, inside the intermediate range 0x20-0x2F, so under
				// the ECMA-48 grammar `\e[3$` is an INCOMPLETE sequence still
				// waiting for its final byte -- and the scan duly waited, then
				// took whatever byte arrived next as that final. Two outcomes,
				// both demonstrated against the shipped editor over a pty:
				// pressing Shift+Delete then typing 'X' DESTROYED the 'X' (a
				// letter is a valid final, so the whole thing was consumed as one
				// unknown sequence); pressing Shift+Delete then Up INJECTED
				// TEXT (ESC is not a valid final, so the old resynchronisation
				// arm dropped `\e[` and re-decoded `3$` as the runes '3' and
				// '$'). Splitting the two keystrokes across reads did not help --
				// the reader accumulates into `pending` and calls back with both.
				//
				// rxvt terminates these sequences AT the '$', which is not
				// ECMA-48 but is what rxvt-unicode's terminfo says (kDC=\e[3$,
				// kIC=\e[2$, kHOM=\e[7$, kEND=\e[8$, kNXT=\e[6$, kPRV=\e[5$), so
				// the fix is to read it that way and hand it to csi_decode as a
				// final. csi_bare_number is what keeps that from stealing DECRPM,
				// whose '$' really is an intermediate; read its comment.
				if j < len(data) && data[j] == '$' && csi_bare_number(data[ps:pe]) {
					if key, tail, ok := csi_decode(data[ps:pe], false, '$', legacy); ok {
						append_key(out, key, tail)
					}
					i = j + 1
					continue
				}
				// The intermediate run is UNBOUNDED here, deliberately. Capping
				// it at ECMA-48's practical two was considered and rejected: the
				// third byte would then be left in the stream, and 0x20-0x2F is
				// printable ASCII, so the cap would REINTRODUCE the leak one byte
				// further along. The parameter scan above is unbounded for the
				// same reason, and the residual cost is identical for both -- a
				// terminal that emits an endless run of parameter or intermediate
				// bytes stalls the reader, which is the `CSI M` trade-off again.
				ims := j
				for j < len(data) && data[j] >= 0x20 && data[j] <= 0x2F { j += 1 }
				if j >= len(data) { return i }   // final byte not arrived yet: hold back
				final := data[j]
				if final < 0x40 || final > 0x7E {
					if j > ims {
						// The intermediate run ended on a byte that CANNOT be a
						// final (a C0, an ESC, a high byte). ECMA-48 says the
						// sequence is malformed; the question is what to do with
						// the bytes, and the old answer -- drop `\e[` and
						// resynchronise -- left every parameter and intermediate
						// byte behind to be typed as runes. They are printable
						// ASCII, so that is silent text injection, not visible
						// garbage. Ending the sequence at the last intermediate
						// instead consumes them and emits nothing, which is the
						// contract every other unrecognised sequence here obeys,
						// and it can never eat the byte that follows.
						i = j
						continue
					}
					// Malformed CSI with no intermediates (e.g. a stray C0/high
					// byte straight after the parameter run): not a sequence in
					// flight, nothing to hold back for. Drop just the introducer
					// so we resynchronise instead of getting stuck.
					i = body
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
					if st != nil { append(&st.markers, Input_Marker{at = len(out), kind = .Paste_Start}) }
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
				// T2-B, LEGACY/X10 MOUSE: `CSI M` followed by exactly THREE
				// RAW BYTES. Dispatched here, ahead of csi_decode, because it
				// is the one construct in this decoder whose length is NOT
				// determined by the CSI grammar -- and getting that wrong is
				// the trap this block exists to avoid.
				//
				// HOW THIS CANNOT CORRUPT THE CSI SCAN, precisely:
				//
				//  1. THE SCAN HAS ALREADY ENDED. The loop above stops at the
				//     first final byte (0x40-0x7E), which for this sequence is
				//     the 'M' at `j`. Everything the scanner ever examines lies
				//     at or before `j`, so the three payload bytes -- which may
				//     be ANY byte value, including 0x1B, '[', 'M', '~', an
				//     invalid UTF-8 lead byte or a NUL -- are never fed to it.
				//     Nor can the resynchronisation arm reach back into them: it
				//     fires only when the byte AT `j` is out of the final-byte
				//     range, which it is not here.
				//  2. THEY ARE NEVER DECODED SEPARATELY. Consumption jumps the
				//     whole six-byte unit in one step (`i = j + 4`), so the top
				//     of the loop resumes strictly after the payload. Consuming
				//     only `j + 1` instead would let the very next iteration
				//     read Cb+32 as a rune -- and a Cy byte of 0x1B would then
				//     introduce a phantom escape sequence that eats the user's
				//     next real keystroke.
				//  3. THE HOLD-BACK IS DECIDED BEFORE ANY PAYLOAD BYTE IS READ.
				//     The length is known from the grammar alone (always three),
				//     so "have all three arrived?" is pure arithmetic on `j` and
				//     `len(data)`. A 0x1B sitting in the payload can therefore
				//     never be mistaken for a sequence in flight, and a split
				//     read can never resolve half a report -- the same
				//     all-or-nothing rule every other sequence here obeys, just
				//     with a length the bytes themselves do not announce.
				//
				// The guard `ps == pe && pe == j` means "no parameter bytes and
				// no intermediates", i.e. a BARE `CSI M`. That is what keeps
				// this arm off the SGR form (`CSI < ... M`, which has
				// parameters) and off anything else ending in 'M'.
				//
				// A `CSI M` never followed by three bytes stalls the decoder on
				// those three bytes -- bounded, like the unterminated-paste case
				// above, and equally unrecoverable without a timer. Accepted for
				// the reason ultraviolet accepts it: on an INPUT stream `CSI M`
				// is a mouse report and nothing else (its output-side meaning,
				// Delete Line, is a sequence a program WRITES).
				if final == 'M' && ps == pe && pe == j {
					if j + 4 > len(data) { return i }   // fewer than three payload bytes: hold back
					if st != nil {
						append(&st.markers, Input_Marker{
							at = len(out), kind = .Mouse,
							mouse = x10_mouse(data[j + 1], data[j + 2], data[j + 3]),
						})
					}
					i = j + 4
					continue
				}
				// T2-B, SGR MOUSE: `CSI < Cb ; Cx ; Cy M|m`. The '<' is a
				// PRIVATE PREFIX BYTE, which csi_params rejects on purpose, so
				// this goes through sgr_mouse -- its own parser, reached only
				// from these two final bytes. Exactly the arrangement 'u'
				// already has with kitty_params, and for the same reason: read
				// csi_params' comment on why that rejection must not be widened.
				//
				// Ordering note: this sits BELOW the X10 block so the bare
				// `CSI M` case is claimed first. The two are disjoint anyway
				// (X10 requires an empty parameter run, SGR requires a '<'), but
				// a reader should not have to prove that to follow the flow.
				if (final == 'M' || final == 'm') && pe == j {
					if m, mok := sgr_mouse(data[ps:pe], final); mok {
						if st != nil {
							append(&st.markers, Input_Marker{at = len(out), kind = .Mouse, mouse = m})
						}
						i = j + 1
						continue
					}
				}
				// T2-B, FOCUS: `CSI I` in, `CSI O` out. Parameterless and
				// intermediate-free by definition, so `\e[1I` is NOT focus and
				// stays on the cleanly-ignored path -- checked rather than
				// assumed, because 'I' and 'O' are ordinary final bytes that
				// some other report could reach with parameters attached.
				//
				// `CSI O` is a different sequence from `ESC O` (SS3): the '[' is
				// what tells them apart, and this branch is already inside the
				// '[' arm.
				if ps == pe && pe == j && (final == 'I' || final == 'O') {
					if st != nil {
						k := Input_Marker_Kind.Focus if final == 'I' else Input_Marker_Kind.Blur
						append(&st.markers, Input_Marker{at = len(out), kind = k})
					}
					i = j + 1
					continue
				}
				if key, tail, ok := csi_decode(data[ps:pe], pe != j, final, legacy); ok {
					append_key(out, key, tail)
				}
				// Whether decoded or not, the sequence is consumed as ONE unit
				// -- "cleanly ignore an unsupported key" rather than leaking
				// its trailing bytes as garbage rune keypresses.
				i = j + 1
				continue
			}
			if intro == 'O' {
				if body >= len(data) {
					// THE AMBIGUITY IS 7-BIT ONLY. `ESC O` with no third byte
					// resolves as Alt+O, because those two bytes are a complete,
					// plausible keypress on their own -- see the ESC O discussion
					// in this proc's doc comment; this is the lone-ESC exception
					// again, not a new one. The 8-bit spelling (0x8F) is NOT
					// ambiguous: SS3 is the only thing that byte can be, so it
					// holds back like any other half-arrived sequence.
					if b != 0x1b { return i }
					append(out, Key_Msg{code = .Rune, r = 'O', mods = {.Alt}})
					return body
				}
				// SS3 grammar: ESC O <digits>* <GL byte 0x21-0x7E>.
				ds := body
				j  := ds
				for j < len(data) && data[j] >= '0' && data[j] <= '9' { j += 1 }
				if j >= len(data) { return i }   // GL byte not arrived yet: hold back
				gl := data[j]
				if gl < 0x21 || gl > 0x7E {
					// Same resynchronisation rule as a malformed CSI above.
					i = body
					continue
				}
				if key, ok := ss3_decode(data[ds:j], gl); ok {
					append(out, key)
				}
				i = j + 1
				continue
			}
			// THE STRING ESCAPES: OSC (']'), DCS ('P'), SOS ('X'), PM ('^') and
			// APC ('_'). Consumed whole to their terminator, emitting nothing --
			// the same "cleanly ignored" contract the CSI and SS3 arms honour,
			// and the same hold-back discipline. Before this arm existed these
			// five introducers fell through to the Alt+key path below and the
			// entire payload was typed into the application; string_escape_end's
			// comment has the measurement and the terminator rules.
			//
			// Nothing here is DECODED yet -- not OSC 8 hyperlinks, not the OSC
			// 10/11 colour replies, not XTVERSION -- because none of them has a
			// Msg to become. Surfacing them is a separate unit; making them stop
			// being keystrokes is not, and is what this arm does.
			if intro == ']' || intro == 'P' || intro == 'X' || intro == '^' || intro == '_' {
				end, ok := string_escape_end(data, body, intro == ']')
				if !ok { return i }   // terminator not arrived yet: hold back
				i = end
				continue
			}
			if b == 0x1b {
				if intro == 0x1b {
					// Double Escape: resolve the first as a real Escape keypress
					// and leave the second ESC byte for the next iteration.
					append(out, decode_c0(0x1b, legacy))
					i += 1
					continue
				}
				// ESC + A C0 BYTE OR DEL == Alt + that KEY, not Alt + that raw
				// rune. This gate is new, and its absence made the comment below
				// it a lie for years: there was no printability test, so ANY byte
				// after ESC went down the rune path. Alt+Enter came out as
				// Key_Msg{code = .Rune, r = '\r', mods = {.Alt}} instead of
				// Enter+{.Alt}; Alt+Backspace as a raw U+007F rune; Alt+Tab as
				// '\t'; and Ctrl+Alt+A as U+0001 with mods = {.Alt} and NO .Ctrl
				// BIT AT ALL, so `k.mods == {.Ctrl, .Alt}` never matched anything.
				//
				// The cost was not a missed binding. examples/editor's
				// `case .Rune: insert_rune(m, k.r)` has no control filter, so one
				// Alt+Enter inserted a raw CR into the document; the .Diff
				// renderer then wrote that control byte to the terminal, which
				// the framework's own view contract declares illegal (a debug
				// build traps on it, a release build silently diverges the cell
				// model from the screen by one column).
				//
				// Routing through decode_c0 rather than hand-building a Key_Msg
				// is the same rule the C0 gate at the bottom of this loop follows:
				// there is ONE C0 policy and it lives in one proc. That does mean
				// `legacy` now reaches the Alt path -- Alt+Enter with .Ctrl_M set
				// is Ctrl+Alt+m, as it should be -- which is a deliberate widening
				// of the note in this proc's doc comment. Ctrl_Open_Bracket is
				// still untouched by it: 0x1b after 0x1b is claimed by the
				// double-Escape arm immediately above, so the byte reaching
				// decode_c0 here is never ESC.
				if intro <= 0x20 || intro == 0x7f {
					k := decode_c0(intro, legacy)
					k.mods += {.Alt}
					append(out, k)
					i = body
					continue
				}
				// ESC followed by a printable byte == Alt+key. Indexed off i+1,
				// not off `body`: `body` is the index PAST the introducer, and
				// here the introducer byte IS the first byte of the rune.
				need := utf8_lead_len(intro)
				if i + 1 + need > len(data) { return i }   // incomplete UTF-8: hold back
				r, w := utf8.decode_rune(data[i + 1:])
				append(out, Key_Msg{code = .Rune, r = r, mods = {.Alt}})
				i += 1 + w
				continue
			}
			// A C1 byte that introduces nothing: xterm's eightBitInput meta
			// encoding, i.e. Alt + the C0 key at `b - 0x80`. See the introducer
			// gate's comment for why this reuses decode_c0 rather than
			// ultraviolet's uppercase-rune arithmetic.
			k := decode_c0(b - 0x80, legacy)
			k.mods += {.Alt}
			append(out, k)
			i += 1
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
