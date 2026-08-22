package mush

// DEBUG_MARK::false
DEBUG_MARK :: true when ODIN_DEBUG else false // stops me from being unable to tell if I'm running the right thing
prompt :: proc(buf: ^Buffer) {
	buf_append(buf, "\r")
	when DEBUG_MARK {
		buf_append(buf, set_foreground(255, 0, 255))
		buf_append(buf, "d")
	}
	if state.last_exit != 0 {
		buf_append(buf, set_foreground(255, 0, 0))
	} else {
		buf_append(buf, set_foreground(0, 0, 255))
	}
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		log.error("can't get current working directory:", err)
	} else {
		home_cstr := posix.getenv("HOME")
		home := string(home_cstr)
		if strings.starts_with(cwd, home) {
			buf_append(buf, "~")
			buf_append(buf, cwd[len(home):])
		} else {
			buf_append(buf, cwd)
		}
	}
	buf_append(buf, " ")
	if state.last_exit != 0 {
		buf_append(buf, fmt.tprint(state.last_exit))
	}
	buf_append(buf, set_foreground(0, 255, 0))
	buf_append(buf, "> ")
	buf_append(buf, set_foreground(255, 255, 255))
	state.need_prompt = false

}
main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}
	logger := log.create_console_logger()
	context.logger = logger
	defer log.destroy_console_logger(logger)
	if terminal.color_depth != .True_Color {
		fmt.eprintln("Terminal doesn't support true color")
		os.exit(1)
	}
	raw_modes()
	defer restore_modes()
	state.win_size = get_window_size()
	{
		frame_buf := Buffer{}
		frame_buf.buf = make([]u8, 256 * mem.Kilobyte)
		defer delete(frame_buf.buf)
		prompt(&frame_buf)
		write_stdout(string(frame_buf.buf[:frame_buf.off]))

	}
	line := [dynamic]u8{}
	arg_arena := virtual.Arena{}
	arena_err := virtual.arena_init_growing(&arg_arena)
	ensure(arena_err == nil, "Buy more ram!")
	arg_allocator := virtual.arena_allocator(&arg_arena)
	main_loop: for !state.should_close {
		free_all(context.temp_allocator)
		frame_buf := Buffer{}
		{
			byte_buf := new([256 * mem.Kilobyte]u8, context.temp_allocator)
			frame_buf.buf = byte_buf[:]
		}
		if state.inject_resize {
			state.inject_resize = false
			state.win_size = get_window_size()
		}
		if state.need_prompt {prompt(&frame_buf)}
		input, ok := read_stdin(time.Millisecond * 16)
		if !ok {
			break
		}
		status: i32 = 0
		should_exec := false
		// TODO: swap this whole guy with a tokenizer instead
		input_loop: for ch, i in input {
			switch ch {
			case '\r':
				buf_append(&frame_buf, "\r\n")
				should_exec = true
				break input_loop
			case:
				// TODO: maybe only let nice characters into line
				ch_str := [1]u8{ch}
				buf_append(&frame_buf, string(ch_str[:]))
				append(&line, ch)
			}
		}
		write_stdout(string(frame_buf.buf[:frame_buf.off]))
		if should_exec {
			args := mush_get_args(line[:], arg_allocator)
			err: Error
			status, err = mush_execute(args)
			clear(&line)
			state.need_prompt = true
		}
	}
}
Buffer :: struct {
	buf: []u8,
	off: int,
}
mush_get_args :: proc(line: []u8, allocator: runtime.Allocator) -> (args: [dynamic][]u8) {
	args = make([dynamic][]u8, allocator)
	Char_Set :: bit_set[cast(u8)0 ..= cast(u8)127]
	Delim: Char_Set = {' ', '\t', '\r', '\a'}
	offset := 0
	for ch, i in line {
		if ch in Delim {
			append(&args, line[offset:i])
			offset = i + 1
		}
	}
	if offset < len(line) {
		append(&args, line[offset:])
	}
	return
}


Error :: enum {
	None,
}
@(require_results)
mush_execute :: proc(args: [dynamic][]u8) -> (exit_code: i32, err: Error) {
	if len(args) == 0 {
		return
	} else if string(args[0]) == "cd" {
		mush_cd(args)
	} else if string(args[0]) == "exit" {
		state.should_close = true
	} else {
		restore_modes()
		pid, errno := linux.fork()
		if pid == 0 {
			when ODIN_DEBUG {
				context.allocator = runtime.default_allocator()
			}
			// restore_modes()
			argczero, argc := make_c_strings(args)
			ret := linux.execve(argczero, argc, posix.environ)
			if ret != nil {
				fmt.eprintfln("Command not found: %s", args[0])
			}
			os.exit(0)
			//assert(ret == 0)
		} else {
			options := linux.Wait_Options{.WEXITED}
			info: linux.Sig_Info
			errno = .EINTR
			for errno == .EINTR {
				errno = linux.waitid(.PID, linux.Id(pid), &info, options + {.WNOWAIT}, nil)
			}
			state.last_exit = info.status
			raw_modes()
		}
	}
	return
}
mush_cd :: proc(args: [dynamic][]u8) {
	if len(args) == 1 {
		home := posix.getenv("HOME")
		posix.chdir(home)
	} else {
		_, argc := make_c_strings(args)
		posix.chdir(cast(cstring)argc[1])
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
@(disabled = ODIN_DISABLE_ASSERT)
wassert :: proc(
	condition: bool,
	message := #caller_expression(condition),
	loc := #caller_location,
) {
	if !condition {
		// NOTE(bill): This is wrapped in a procedure call
		// to improve performance to make the CPU not
		// execute speculatively, making it about an order of
		// magnitude faster
		@(cold)
		internal :: proc(message: string, loc: runtime.Source_Code_Location) {
			log.warn("runtime wassert", message, loc)
		}
		internal(message, loc)
	}
}
set_foreground :: proc(r: u8, g: u8, b: u8) -> string {
	return fmt.tprint(ansi.CSI, ansi.FG_COLOR_24_BIT, ";", r, ";", g, ";", b, ansi.SGR, sep = "")
}
set_background :: proc(r: u8, g: u8, b: u8) -> string {
	return fmt.tprint(ansi.CSI, ansi.BG_COLOR_24_BIT, ";", r, ";", g, ";", b, ansi.SGR, sep = "")
}
buf_append :: proc(buf: ^Buffer, str: string) -> (count: int, ok: bool) {
	str := transmute([]u8)str
	left := len(buf.buf) - buf.off
	can_do := max(min(left, len(str)), 0)
	mem.copy(&buf.buf[buf.off], &str[0], can_do)
	buf.off += can_do
	success := can_do == len(str)
	wassert(success)
	return can_do, success
}

State :: struct {
	stdin:                  linux.Fd,
	stdin_flags:            linux.Open_Flags,
	stdout:                 linux.Fd,
	stdout_initial_termios: posix.termios,
	// Buffer for incomplete UTF-8 sequences (max 4 bytes needed)
	inject_resize:          bool,
	utf8_buf:               [4]u8,
	utf8_len:               int,
	win_size:               [2]u16,
	should_close:           bool,
	need_prompt:            bool,
	last_exit:              i32,
}
state := State {
	stdin    = linux.STDIN_FILENO,
	stdout   = linux.STDOUT_FILENO,
	win_size = {80, 24},
}
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:terminal"
import "core:terminal/ansi"
import "core:time"
