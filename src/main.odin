package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import psx "core:sys/posix"

main :: proc() {
	enableRawMode()
	defer disableRawMode()
	mush_loop()

}
mush_loop :: proc() {
	prmpt: [2]u8 = "> "
	status: i32 = 0
	for status == 0 {
		psx.write(psx.STDIN_FILENO, &prmpt[0], 2)
		line := mush_readline()
		args := mush_get_args(line)
		status = mush_execute(args)
	}
}

mush_readline :: proc() -> [dynamic]u8 {
	line: [dynamic]u8
	for {
		ch: [1]u8
		psx.read(psx.STDIN_FILENO, &ch[0], 1)
		if ch[0] <= 0 {continue}
		if ch[0] == '\r' || ch[0] == '\n' {
			carriagereturn: [2]u8 = "\r\n"
			psx.write(psx.STDOUT_FILENO, &carriagereturn[0], 2)

			break
		}
		if ch[0] >= ' ' && ch[0] <= '~' {
			fmt.printf("%c", ch[0])
			append(&line, ch[0])

		} else if ((ch == 127 || ch == '\b') && len(line) > 0) { 	// delete  key
			bs_seq: [3]u8 = "\b \b"
			psx.write(psx.STDOUT_FILENO, &bs_seq[0], 3)
			pop(&line)
		}
	}
	return line
}

mush_get_args :: proc(line: [dynamic]u8) -> [dynamic][]u8 {
	args: [dynamic][]u8
	Char_Set :: bit_set[cast(u8)0 ..= cast(u8)127]
	Delim: Char_Set = {' ', '\t', '\r', '\n', '\a'}

	start := 0

	for i in 0 ..< len(line) {
		if line[i] in Delim {
			if i > start {
				append(&args, line[start:i])
			}
			start = i + 1
		}
	}

	if start < len(line) {
		append(&args, line[start:])
	}


	return args
}


mush_execute :: proc(args: [dynamic][]u8) -> i32 {
	status: i32 = 0
	if len(args) == 0 {
		return 0
	} else if (strings.compare(cast(string)args[0], "cd") == 0) {
		mush_cd(args)
	} else {
		pid := psx.fork()
		if pid == 0 {
			argczero, argc := make_c_strings(args)
			ret := psx.execvp(argczero, argc)
			if ret != 0 {
				fmt.printfln("Command not found: %s", args[0])
			}
			//assert(ret == 0)
		} else {
			flags := bit_set[psx.Wait_Flag_Bits;i32]{.UNTRACED}
			// Parent process
			psx.waitpid(pid, &status, flags)
			for (!psx.WIFEXITED(status) && !psx.WIFSIGNALED(status)) {
				psx.waitpid(pid, &status, flags)
				//psx.waitpid(pid, &status, psx.WUNTRACED)
			}
		}

	}
	return status
}
mush_cd :: proc(args: [dynamic][]u8) {
	//fmt.print(len(args))
	if len(args) == 1 {
		home := psx.getenv("HOME")
		psx.chdir(home)
	} else {
		_, argc := make_c_strings(args)
		psx.chdir(cast(cstring)argc[1])
	}
}

make_c_strings :: proc(
	tokens: [dynamic][]u8,
	allocator := context.allocator,
) -> (
	cstring,
	[^]cstring,
) {

	arena_backing := make([]u8, 4 * mem.Kilobyte)
	arena: mem.Arena
	mem.arena_init(&arena, arena_backing)
	arena_allocator := mem.arena_allocator(&arena)

	// Allocate array of cstrings (with extra slot for nil terminator)
	c_args := make([]cstring, len(tokens) + 1, arena_allocator)

	// Convert each token to null-terminated C string
	for token, i in tokens {
		// Create null-terminated copy
		nt_token := make([]u8, len(token) + 1, arena_allocator)
		copy(nt_token, token)
		nt_token[len(token)] = 0 // Null terminator

		// Store as cstring
		c_args[i] = cstring(raw_data(nt_token))
	}

	// Last element must be nil
	c_args[len(tokens)] = nil

	// Return the command and arguments
	return c_args[0], raw_data(c_args)
}
