package main

// Validates the recursive, RUNTIME is_pod_type check meant for arena.odin's
// box(). Confirmed earlier (see git history of this file) that Odin cannot
// fold a user-defined recursive proc into a `when`/`#assert` compile-time
// constant even when its body is built entirely from const-foldable
// intrinsics -- so this is deliberately a runtime check, called from box()
// with a `panic()` (not `assert()`, so it survives -disable-assert, per
// guard.odin's FIX 3 precedent) rather than a `when`-gated compile error.

import "core:fmt"
import "base:intrinsics"
import "base:runtime"

is_pod_type :: proc(id: typeid) -> bool {
	ti := type_info_of(id)
	return is_pod_info(ti)
}

@(private = "file")
is_pod_info :: proc(ti: ^runtime.Type_Info) -> bool {
	if ti == nil { return true }
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return is_pod_info(v.base)
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer,
	     runtime.Type_Info_String,
	     runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array,
	     runtime.Type_Info_Map, runtime.Type_Info_Any,
	     runtime.Type_Info_Soa_Pointer:
		return false
	case runtime.Type_Info_Struct:
		types := v.types[:v.field_count]
		for t in types {
			if !is_pod_info(t) { return false }
		}
		return true
	case runtime.Type_Info_Array:
		return is_pod_info(v.elem)
	case runtime.Type_Info_Enumerated_Array:
		return is_pod_info(v.elem)
	case runtime.Type_Info_Union:
		for t in v.variants {
			if !is_pod_info(t) { return false }
		}
		return true
	}
	// Integer, Rune, Float, Complex, Quaternion, Boolean, Enum, Bit_Set,
	// Bit_Field, Simd_Vector, Matrix, Procedure, Type_Id -- none of these
	// carry an owned heap allocation.
	return true
}

Key_Kind :: enum u8 { Press, Release }
Key_Code :: enum u8 { Rune, Enter, Escape }
Modifier  :: enum u8 { Ctrl, Alt, Shift }
Modifiers :: bit_set[Modifier; u8]
Key_Msg :: struct { kind: Key_Kind, code: Key_Code, r: rune, mods: Modifiers }

Window_Size_Msg :: struct { w, h: int }
Quit_Msg :: struct {}

Bad_String  :: struct { reason: string }
Bad_Slice   :: struct { xs: []int }
Bad_Pointer :: struct { p: ^int }
Bad_Nested  :: struct { inner: struct { s: string } }
Bad_Array   :: struct { ps: [4]^int }

Msg_Text :: struct { buf: [255]u8, len: u8 }
Good_With_Text :: struct { reason: Msg_Text }

Good_Union :: struct { u: union { int, Key_Msg } }
Bad_Union  :: struct { u: union { int, string } }

main :: proc() {
	check :: proc(name: string, id: typeid, want: bool) {
		got := is_pod_type(id)
		mark := "OK" if got == want else "FAIL"
		fmt.printfln("[%s] %-16s is_pod=%v (want %v)", mark, name, got, want)
	}
	check("Key_Msg", Key_Msg, true)
	check("Window_Size_Msg", Window_Size_Msg, true)
	check("Quit_Msg", Quit_Msg, true)
	check("Good_With_Text", Good_With_Text, true)
	check("Good_Union", Good_Union, true)
	check("Bad_String", Bad_String, false)
	check("Bad_Slice", Bad_Slice, false)
	check("Bad_Pointer", Bad_Pointer, false)
	check("Bad_Nested", Bad_Nested, false)
	check("Bad_Array", Bad_Array, false)
	check("Bad_Union", Bad_Union, false)
	check("int", int, true)
	check("string", string, false)
}
