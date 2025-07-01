package main

import "base:runtime"
import "core:fmt"
import psx "core:sys/posix"

orig_termios: (psx.termios)
die :: proc(_: string) {
	fmt.print("\x1b[2J")
	fmt.print("\x1b[H")
	psx.exit(1)

}
disableRawMode :: proc "c" () {
	res := psx.tcsetattr(psx.STDIN_FILENO, .TCSAFLUSH, &orig_termios)
	context = runtime.default_context()
	assert(res == .OK)
	//die("tcsetattr")
}

enableRawMode :: proc() {

	res := psx.tcgetattr(psx.STDIN_FILENO, &orig_termios)
	assert(res == .OK)
	psx.atexit(disableRawMode)

	raw: psx.termios = orig_termios

	raw.c_lflag -= {.ICANON, .ECHO}
	//raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
	//raw.c_oflag &= ~(OPOST);
	//raw.c_cflag |= (CS8);
	//raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);

	raw.c_cc[cast(psx.Control_Char)psx.VMIN] = 0
	raw.c_cc[cast(psx.Control_Char)psx.VTIME] = 1


	res = psx.tcsetattr(psx.STDIN_FILENO, .TCSAFLUSH, &raw)
	assert(res == .OK)
}
