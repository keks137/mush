package mush
set_green :: proc(buf: ^Buffer) {
	buf_append(buf, ansi.CSI + ansi.FG_COLOR_24_BIT + ";0;255;0" + ansi.SGR)

}
set_red :: proc(buf: ^Buffer) {
	buf_append(buf, ansi.CSI + ansi.FG_COLOR_24_BIT + ";252;25;17" + ansi.SGR)
}
// DEBUG_MARK::false
DEBUG_MARK :: true when ODIN_DEBUG else false // stops me from being unable to tell if I'm running the right thing
prompt :: proc(buf: ^Buffer) {
	// buf_append(buf, "\r")
	buf_append(buf, "\r\x1b[2K")
	when DEBUG_MARK {
		buf_append(buf, ansi.CSI + ansi.FG_COLOR_24_BIT + ";255;0;255" + ansi.SGR)
		buf_append(buf, "d")
	}
	if state.last_exit != 0 {
		set_red(buf)
	} else {
		buf_append(buf, ansi.CSI + ansi.FG_COLOR_24_BIT + ";53;109;247" + ansi.SGR)
	}
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		log.error("can't get current working directory:", err)
	} else {
		home_cstr := posix.getenv("HOME")
		home := string(home_cstr)
		if strings.starts_with(cwd, home) {
			buf_append(buf, "~")
			pretty_name := cwd[len(home):]
			if len(pretty_name) > 0 {
				buf_append(buf, pretty_name)
			}
		} else {
			buf_append(buf, cwd)
		}
	}
	buf_append(buf, " ")
	if state.last_exit != 0 {
		buf_append(buf, fmt.tprint(state.last_exit))
	}
	set_green(buf)
	buf_append(buf, "> ")
	buf_append(buf, ansi.CSI + ansi.FG_COLOR_24_BIT + ";255;255;255" + ansi.SGR)
}
ctrl_key :: proc(ch: u8) -> u8 {
	return ch & 0x1f
}
TokenKind :: enum {
	Invalid,
	Word,
	ArrowLeft,
	ArrowRight,
	ArrowUp,
	ArrowDown,
	Backspace,
	Newline,
	String,
	EOF,
}
Pos :: struct {
	offset: int,
}
Token :: struct {
	kind:      TokenKind,
	using pos: Pos,
	word:      []u8,
}
Tokenizer :: struct {
	using pos:        Pos,
	prev:             Token,
	current:          Token,
	curr_line_offset: int,
	ch:               rune,
	w:                int,
	src:              []u8,
	filename:         string,
}
get_token :: proc(s: ^Tokenizer) -> Token {
	skip_whitespace :: proc(s: ^Tokenizer) -> rune {
		for s.offset < len(s.src) {
			switch s.ch {
			case ' ', '\t', '\f', '\v':
				next_rune(s)
			case:
				return s.ch
			}
		}
		return s.ch
	}
	skip_digits :: proc(s: ^Tokenizer) {
		for s.offset < len(s.src) {
			switch s.ch {
			case '0' ..= '9':
				next_rune(s)
			case:
				return
			}
		}
	}

	skip_whitespace(s)
	tok := Token{}
	tok.pos = s.pos
	ch := s.ch
	next_rune(s)
	switch ch {
	case utf8.RUNE_ERROR:
		syntax_error(s, tok.pos, "illegal character found: %c", ch)
	case utf8.RUNE_EOF, '\x00':
		tok.kind = .EOF
	case '\n':
		tok.kind = .Newline
	case '\r':
		tok.kind = .Newline
		if s.ch == '\n' {
			next_rune(s)
		}
	case '"':
		tok.kind = .String
		for s.offset < len(s.src) {
			char := s.ch
			if char == '\n' || char < 0 || (s.offset == len(s.src) - 1 && char != '"') {
				syntax_error(s, tok.pos, "string literal not terminated")
				break
			}
			next_rune(s)
			if char == '"' {
				break
			}
			if char == '\\' {
				// TODO:
			}
		}
	case 'A' ..= 'Z', 'a' ..= 'z', '_', '.', '/', '-', '~':
		tok.kind = .Word
		ident_loop: for s.offset < len(s.src) {
			switch s.ch {
			case ' ', '\t', '\r', '\f', '\v':
				break ident_loop
			case:
				next_rune(s)
			}
		}
		str := s.src[tok.offset:s.offset]
	// for keyword in TokenKind.And ..< TokenKind(len(TokenKind)) {
	// 	if token_kind_string[keyword] == str {
	// 		tok.kind = keyword
	// 		break
	// 	}
	// }
	case:
		syntax_error(s, tok.pos, "Unexpected character: '%c', code %x", ch, ch)
	}

	tok.word = s.src[tok.offset:s.offset]
	return tok
}
syntax_error :: proc(t: ^Tokenizer, pos: Pos, format: string, args: ..any) {
	fmt.eprintf("Syntax Error: ")
	fmt.eprintf(format, args = args)
	fmt.eprintln()
	error_count += 1
}
next_rune :: proc(t: ^Tokenizer) -> rune {
	if t.offset < len(t.src) {
		t.offset += t.w
		t.ch, t.w = utf8.decode_rune_in_string(string(t.src[t.offset:]))
		// scanner.pos.column = scanner.offset - scanner.curr_line_offset
	}

	if t.offset >= len(t.src) {
		t.ch = utf8.RUNE_EOF
		t.w = 1
	}
	return t.ch
}


PROFILING :: true
when PROFILING {
	SCOPED_EVENT :: spall.SCOPED_EVENT
	spall_ctx: spall.Context
	@(thread_local)
	spall_buffer: spall.Buffer
	@(instrumentation_enter)
	spall_enter :: proc "contextless" (
		proc_address, call_site_return_address: rawptr,
		loc: runtime.Source_Code_Location,
	) {
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (
		proc_address, call_site_return_address: rawptr,
		loc: runtime.Source_Code_Location,
	) {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}
}

error_count := 0
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
	when PROFILING {
		spall_ctx = spall.context_create("trace_test.spall")
		defer spall.context_destroy(&spall_ctx)

		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

		SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
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
		buf_append(&frame_buf, ansi.CSI + ansi.DECTCEM_HIDE)
		prompt(&frame_buf)
		write_stdout(string(frame_buf.buf[:frame_buf.off]))

	}
	t := Tokenizer{}
	line_bufs := [2][dynamic]u8{}
	in_buf := &line_bufs[0]
	processed_buf := &line_bufs[1]
	defer delete(line_bufs[0])
	defer delete(line_bufs[1])
	exec_args: []Token
	line_tokens := [dynamic]Token{}
	defer delete(line_tokens)
	arg_arena := virtual.Arena{}
	arena_err := virtual.arena_init_growing(&arg_arena)
	ensure(arena_err == nil, "Buy more ram!")
	arg_allocator := virtual.arena_allocator(&arg_arena)
	main_loop: for !state.should_close {
		SCOPED_EVENT(&spall_ctx, &spall_buffer, "cycle")
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
		prompt(&frame_buf)
		input, ok := read_stdin(time.Second * 3)
		if !ok {
			break
		}
		should_cancel := false
		if len(input) > 0 {
			SCOPED_EVENT(&spall_ctx, &spall_buffer, "input handling")
			{
				tmp := in_buf
				in_buf = processed_buf
				processed_buf = tmp
			}
			assert(in_buf != processed_buf)
			clear(&line_tokens)
			clear(processed_buf)
			append(in_buf, ..input[:])
			state.cursor_offset = 0
			edit_loop: for i := 0; i < len(in_buf); i += 1 {
				SCOPED_EVENT(&spall_ctx, &spall_buffer, "edit_loop")
				ch := in_buf[i]
				switch ch {
				case '\b', '\x7f':
					if state.cursor_offset > 0 {
						state.cursor_offset -= 1
						ordered_remove(processed_buf, state.cursor_offset)
					}
				case '\e':
					if (len(in_buf) > i + 1) {
						i += 1
						ch = in_buf[i]
						if ch == '[' {
							if (len(in_buf) > i + 1) {
								i += 1
								ch = in_buf[i]
								switch ch {
								case 'D':
									//left
									if state.cursor_offset > 0 {
										state.cursor_offset -= 1
									}
								}
							}
						}
					}
				case:
					if ch == ctrl_key('d') {
						if len(processed_buf) == 0 {
							state.should_close = true
							buf_append(&frame_buf, "\r\n")
						}
					} else if ch == ctrl_key('c') {
						state.last_exit = 130
						should_cancel = true
						inject_at(processed_buf, state.cursor_offset, '\n')
					} else {
						inject_at(processed_buf, state.cursor_offset, ch)
						state.cursor_offset += 1
					}
				}
			}
			t = {}
			t.src = processed_buf[:]
			next_rune(&t)
			for {
				tok := get_token(&t)
				append(&line_tokens, tok)
				if tok.kind == .EOF {break}
			}
			exec_args = line_tokens[:]
			// fmt.println("\rin_buf:", in_buf)
			// fmt.println("\rprocessed_buf:", processed_buf)
			// fmt.println("\rline_tokens:", line_tokens)
		}
		args, should_exec := parse_args(exec_args, &frame_buf, arg_allocator)
		write_stdout(string(frame_buf.buf[:frame_buf.off]))
		if should_cancel {
			clear(in_buf)
			clear(processed_buf)
			state.cursor_offset = 0
			exec_args = {}
		} else if should_exec {
			err: Error
			err = mush_execute(args)
			clear(in_buf)
			clear(processed_buf)
			state.cursor_offset = 0
			exec_args = {}
		}
	}
}
Buffer :: struct {
	buf: []u8,
	off: int,
}
parse_args :: proc(
	toks: []Token,
	frame_buf: ^Buffer,
	allocator: runtime.Allocator,
) -> (
	args: [dynamic][]u8,
	should_exec: bool,
) {
	if len(toks) > 0 {
		args = make([dynamic][]u8, allocator)
		cmd := toks[0]
		toks := toks[1:]
		#partial switch cmd.kind {
		case .Word:
			set_red(frame_buf)
			_, found := get_builtin(string(cmd.word))
			if !found {
				if cmd.word[0] == '.' {
					_, patherr := filepath.abs(string(cmd.word), context.temp_allocator)
					found = patherr == nil
				}
			}
			if !found {
				path_cstr := posix.getenv("PATH")
				if path_cstr == nil {
					path_cstr = "/bin:/usr/bin"
				}
				path := string(path_cstr)
				entries := strings.split(path, ":", context.temp_allocator)
				for entry in entries {
					potential_path := strings.concatenate(
						{entry, "/", string(cmd.word), "\x00"},
						context.temp_allocator,
					)
					potential_path_cstr := transmute(cstring)raw_data(potential_path)
					if linux.access(potential_path_cstr) == nil {
						found = true
						break
					}
				}
			}
			if found {
				set_green(frame_buf)
			}
			buf_append(frame_buf, string(cmd.word))
			buf_append(frame_buf, " ")
			append(&args, cmd.word)
			buf_append(frame_buf, set_foreground(255, 255, 255))
			for tok, i in toks {
				switch tok.kind {
				case .Newline:
					buf_append(frame_buf, "\r\n")
					should_exec = true
				case .String:
					buf_append(frame_buf, string(tok.word))
					append(&args, tok.word[1:len(tok.word) - 1]) // remove quotes
					buf_append(frame_buf, " ")
				case .Word:
					buf_append(frame_buf, string(tok.word))
					buf_append(frame_buf, " ")
					append(&args, tok.word)
				case .EOF:
					assert(i == len(toks) - 1)
				case .Invalid, .ArrowLeft, .ArrowRight, .ArrowUp, .ArrowDown, .Backspace:
					fmt.eprintln(tok)
					ensure(false, "aaaaa")
				}
			}

		case .EOF:
			assert(len(toks) == 0)
		case .Newline:
			buf_append(frame_buf, "\r\n")
			should_exec = true
		case:
			fmt.eprintln("Not a command:", cmd)
			state.last_exit = 1
		}
	}
	return
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

BuiltinCommand :: enum {
	Cd,
	Exit,
}
builtin_commands := [BuiltinCommand]string {
	.Cd   = "cd",
	.Exit = "exit",
}
Error :: enum {
	None,
}
get_builtin :: proc(cmd: string) -> (builtin_cmd: BuiltinCommand, ok: bool) {
	for i in BuiltinCommand(0) ..= max(BuiltinCommand) {
		builtin_cmd = i
		if cmd == builtin_commands[i] {
			ok = true
			break
		}
	}
	return
}
@(require_results)
mush_execute :: proc(args: [dynamic][]u8) -> (err: Error) {
	if len(args) == 0 {
		return
	} else if cmd, ok := get_builtin(string(args[0])); ok {
		switch cmd {
		case .Exit:
			state.should_close = true
		case .Cd:
			mush_cd(args)
		}
	} else {
		restore_modes()
		pid, errno := linux.fork()
		if pid == 0 {
			when ODIN_DEBUG {
				context.allocator = runtime.default_allocator()
			}
			argc := make([^]cstring, len(args))
			for arg, i in args {
				argc[i] = strings.clone_to_cstring(string(arg))
			}
			executable := argc[0]
			// restore_modes()

			if args[0][0] == '.' {
				execpath, err_path := filepath.abs(string(args[0]), context.temp_allocator)
				if err_path == nil {
					executable = strings.clone_to_cstring(execpath)
				}
			} else {
				path_cstr := posix.getenv("PATH")
				if path_cstr == nil {
					path_cstr = "/bin:/usr/bin"
				}
				path := string(path_cstr)
				entries := strings.split(path, ":", context.temp_allocator)
				for entry in entries {
					potential_path := strings.concatenate(
						{entry, "/", string(args[0]), "\x00"},
						context.temp_allocator,
					)
					potential_path_cstr := transmute(cstring)raw_data(potential_path)
					if linux.access(potential_path_cstr) == nil {
						executable = potential_path_cstr
						break
					}
				}
			}
			ret := linux.execve(executable, argc, posix.environ)
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
			write_stdout(ansi.CSI + ansi.DECTCEM_HIDE)
		}
	}
	return
}
mush_cd :: proc(args: [dynamic][]u8) {
	if len(args) == 1 {
		home := posix.getenv("HOME")
		errno := linux.chdir(home)
		if errno != nil {
			fmt.eprintln("Can't cd to '", home, "', ", errno, sep = "")
		}
	} else {
		dst: cstring
		if args[1][0] == '~' {
			home_cstr := posix.getenv("HOME")
			home := string(home_cstr)
			length := len(args[1]) + len(home) - 1 // remove '~'
			c := make([]byte, length + 1, context.temp_allocator)
			copy(c, home[:])
			rest := c[len(home):]
			copy(rest, args[1][1:])
			c[length] = 0
			dst = cstring(&c[0])
		} else {
			dst = strings.clone_to_cstring(string(args[1]), context.temp_allocator)
		}
		errno := linux.chdir(dst)
		if errno != nil {
			fmt.eprintln("Can't cd to '", dst, "', ", errno, sep = "")
		}
	}
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
	// fmt.printfln("appending %w\r", str)
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
	cursor_offset:          int,
	inject_resize:          bool,
	utf8_buf:               [4]u8,
	utf8_len:               int,
	win_size:               [2]u16,
	should_close:           bool,
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
import "core:path/filepath"
import "core:prof/spall"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:terminal"
import "core:terminal/ansi"
import "core:time"
import "core:unicode/utf8"
