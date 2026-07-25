package runetea

import "core:testing"

@(test)
test_guard_recovers_panic :: proc(t: ^testing.T) {
	info := guarded(proc(ud: rawptr) { panic("boom in user update") }, nil)
	testing.expect(t, info.recovered, "expected recovery from panic")
	testing.expect_value(t, info.message, "boom in user update")
	delete(info.message)
}

@(test)
test_guard_recovers_bad_type_assertion :: proc(t: ^testing.T) {
	info := guarded(proc(ud: rawptr) {
		x: any = int(3)
		_ = x.(f64)   // wrong type -> runtime assertion
	}, nil)
	testing.expect(t, info.recovered, "expected recovery from bad type assertion")
	delete(info.message)
}

@(test)
test_guard_returns_normally_when_no_panic :: proc(t: ^testing.T) {
	hit := false
	info := guarded(proc(ud: rawptr) { (cast(^bool)ud)^ = true }, &hit)
	testing.expect(t, !info.recovered, "should not report recovery")
	testing.expect(t, hit, "body should have run")
}

@(test)
test_guard_restores_assertion_proc :: proc(t: ^testing.T) {
	before := context.assertion_failure_proc
	info := guarded(proc(ud: rawptr) { panic("x") }, nil)
	delete(info.message)
	testing.expect(t, context.assertion_failure_proc == before,
		"guarded must restore the previous assertion_failure_proc")
}
