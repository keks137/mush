package mush

restore_modes :: proc() {
	res := posix.tcsetattr(posix.FD(state.stdout), .TCSANOW, &state.stdout_initial_termios)
	ensure(res == .OK)
	//show cursor
	write_stdout(ansi.CSI + ansi.DECTCEM_SHOW)

}

ensure :: proc(
	condition: bool,
	message := #caller_expression(condition),
	loc := #caller_location,
) {
	if !condition {
		@(cold)
		internal :: proc(message: string, loc: runtime.Source_Code_Location) {
			restore_modes()
			p := context.assertion_failure_proc
			if p == nil {
				p = runtime.default_assertion_failure_proc
			}
			p("unsatisfied ensure", message, loc)
		}
		internal(message, loc)
	}
}


raw_modes :: proc() {
	err: linux.Errno
	state.stdin_flags, err = linux.fcntl(state.stdin, linux.F_GETFL)
	ensure(err == nil)
	sigwinch_action := posix.sigaction_t{}
	sigwinch_action.sa_handler = sigwinch_handler
	res := posix.sigaction(posix.Signal(posix.SIGWINCH), &sigwinch_action, nil)
	ensure(res == .OK)
	termios := posix.termios{}
	res = posix.tcgetattr(posix.FD(state.stdout), &termios)
	ensure(res == .OK)
	state.stdout_initial_termios = termios
	termios.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .INPCK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	termios.c_oflag -= {.OPOST}
	termios.c_cflag -= {.PARENB}
	raw_c_cflag := cast(^posix.tcflag_t)&termios.c_cflag
	raw_c_cflag^ &= ~posix.tcflag_t(posix._CSIZE)
	termios.c_cflag += {.CS8}
	termios.c_lflag -= {.ISIG, .ECHO, .ECHONL, .IEXTEN, .ICANON}
	res = posix.tcsetattr(posix.FD(state.stdout), .TCSANOW, &termios)
	ensure(res == .OK)
}
sigwinch_handler :: proc "c" (sig: posix.Signal) {
	state.inject_resize = true
}
import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"
import "core:terminal/ansi"
import "core:time"
