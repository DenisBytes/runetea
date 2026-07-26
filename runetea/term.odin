package runetea

import "core:sys/linux"
import "core:sys/posix"

Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

Term_State :: struct {
	fd:         posix.FD,
	saved:      posix.termios,
	raw_active: bool,
}

// Process-global: signal handlers take no arguments and must reach this.
g_term: Term_State

term_enter_raw :: proc(fd: posix.FD) -> bool {
	if posix.tcgetattr(fd, &g_term.saved) != .OK { return false }

	// ORDERING INVARIANT: raw_active must be true for the entire interval in
	// which the tty could possibly be in raw mode, and g_term.saved must be
	// valid before raw_active is ever true. g_term.saved holds valid
	// cooked-mode settings as of the line above, so it is safe to flip
	// raw_active on now, before tcsetattr below has actually touched the
	// terminal. A crash signal landing anywhere from here through the
	// tcsetattr call sees raw_active == true and calls term_restore_c(),
	// which re-applies g_term.saved -- correct and harmless whether the tty
	// is still cooked or has just become raw. Setting raw_active only after
	// tcsetattr succeeds would leave a window where the tty is already raw
	// but term_restore_c() no-ops, stranding the terminal with no recovery.
	g_term.fd = fd
	g_term.raw_active = true

	raw := g_term.saved

	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}

	// Do NOT write CControl_Flags{.CS8}: the enum member is log2(CS8) and CS8
	// (0x30) is multi-bit, so it truncates to bit 5 == CS7 (0x20), silently
	// running the tty at 7-bit character size.
	raw.c_cflag -= transmute(posix.CControl_Flags)posix.tcflag_t(posix.CSIZE)
	raw.c_cflag += transmute(posix.CControl_Flags)posix.tcflag_t(posix.CS8)

	raw.c_cc[.VMIN]  = 1
	raw.c_cc[.VTIME] = 0

	if posix.tcsetattr(fd, .TCSAFLUSH, &raw) != .OK {
		// Roll back: the tty was never actually put into raw mode.
		g_term.raw_active = false
		return false
	}
	return true
}

term_restore :: proc() {
	term_restore_c()
}

// Async-signal-safe: tcsetattr(2) only. No allocation, no locks.
//
// Emits no escape sequences (FIX 5, final fix-wave report). This used to
// unconditionally write "\e[?1049l\e[?25h" -- leave alt screen, show
// cursor -- on every exit path, but nothing in this package or its
// examples ever writes the corresponding entry sequences ("\e[?1049h",
// "\e[?25l"): render.odin is a naive INLINE rewind renderer (cursor-up +
// erase-line, see renderer_render), not an alt-screen renderer, and the
// cursor is never hidden. Restore must undo only what was actually set --
// right now that is termios raw mode, nothing else. The old unconditional
// write was an alt-screen EXIT the framework never entered: on
// xterm-family terminals an unpaired "\e[?1049l" restores a cursor
// position that was never saved, which is actively wrong output, not
// merely a harmless no-op. T2/T3 may start hiding the cursor and/or
// entering the alt screen; this restore must grow to match exactly that
// when it does, and no more in the meantime.
term_restore_c :: proc "c" () {
	if !g_term.raw_active { return }
	posix.tcsetattr(g_term.fd, .TCSAFLUSH, &g_term.saved)
	g_term.raw_active = false
}

// core:sys/posix exposes neither ioctl nor a winsize struct; only the per-OS
// TIOCGWINSZ constant exists. Go through the raw Linux syscall layer.
//
// linux.ioctl returns uintptr, NOT an Errno -- errors are negative returns.
term_size :: proc(fd: posix.FD) -> (w: int, h: int, ok: bool) {
	ws := Winsize{}
	res := linux.ioctl(linux.Fd(fd), linux.TIOCGWINSZ, uintptr(rawptr(&ws)))
	if int(res) < 0 { return 0, 0, false }
	if ws.ws_col == 0 || ws.ws_row == 0 { return 0, 0, false }
	return int(ws.ws_col), int(ws.ws_row), true
}
