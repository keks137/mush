package mush
read_stdin :: proc(
	timeout: time.Duration,
	allocator: runtime.Allocator = context.temp_allocator,
) -> (
	text: []u8,
	ok: bool,
) {
	timeout := timeout
	if state.inject_resize {timeout = 0}
	byte_buf := new([4 * mem.Kilobyte]u8, allocator)
	buf: Buffer
	buf.buf = byte_buf[:]
	if state.utf8_len != 0 {
		copy(buf.buf, state.utf8_buf[:state.utf8_len])
		buf.off += state.utf8_len
		state.utf8_len = 0
	}
	loop: for {
		SCOPED_EVENT(&spall_ctx, &spall_buffer, "read cycle")
		buf_rest := byte_buf[buf.off:len(buf.buf)]
		beg := time.now()
		pollfd := linux.Poll_Fd {
			fd      = state.stdin,
			events  = {.IN},
			revents = nil,
		}
		pollfds := [?]linux.Poll_Fd{pollfd}
		ts := to_timespec(timeout)
		reti32, errno := linux.ppoll(pollfds[:], &ts, nil)
		if reti32 < 0 {
			return
		} else if reti32 == 0 {
			break // Timeout, probably
		}
		timeout = max(0, timeout - time.since(beg))
		set_tty_nonblocking(true)
		ret: int
		assert(len(buf_rest) > 0)
		ret, errno = linux.read(state.stdin, buf_rest[:])
		if ret > 0 {
			buf.off = buf.off + ret
			break
		} else if ret == 0 {
			return
		} else if ret < 0 {
			#partial switch errno {
			case .EINTR:
				if state.inject_resize {break loop}
			case .EAGAIN:
				if timeout == 0 {break loop}
			case:
				return
			}
		}
	}
	SCOPED_EVENT(&spall_ctx, &spall_buffer, "UTF8 stuff")
	if buf.off > 0 {
		lim := max(buf.off - 3, 0)
		off := buf.off - 1
		for off > lim && byte_buf[off] & 0b1100_0000 == 0b1000_0000 {
			off -= 1
		}
		seq_len := 0
		b := byte_buf[off]
		switch {
		case b & 0b1000_0000 == 0:
			seq_len = 1
		case b & 0b1110_0000 == 0b1100_0000:
			seq_len = 2
		case b & 0b1111_0000 == 0b1110_0000:
			seq_len = 3
		case b & 0b1111_1000 == 0b1111_0000:
			seq_len = 4
		}
		if off + seq_len > buf.off {
			state.utf8_len = buf.off - off
			copy(state.utf8_buf[:], byte_buf[off:])
			buf.off = off
		}
	}
	// TODO: UTF8 validation
	ok = true
	text = byte_buf[:buf.off]
	return
}
write_stdout :: proc(text: string) {
	if text == "" {return}
	set_tty_nonblocking(false)
	buf := transmute([]u8)text
	written := 0
	for written < len(buf) {
		w := buf[written:min(len(buf), mem.Gigabyte)]
		n, errno := linux.write(state.stdout, w)
		if n >= 0 {
			written += n
			continue
		}
		if errno != .EINTR {
			return
		}
	}
}
set_tty_nonblocking :: proc(nonblock: bool) {
	is_nonblock := linux.Open_Flags_Bits.NONBLOCK in state.stdin_flags
	if is_nonblock != nonblock {
		state.stdin_flags ~= {.NONBLOCK}
		err := linux.fcntl(state.stdin, linux.F_SETFL, state.stdin_flags)
		ensure(err == nil)
	}
}
get_window_size :: proc() -> [2]u16 {
	winsz: [4]u16 // NOTE: x is y and y is x
	for i in 0 ..< 10 {
		ret := linux.ioctl(state.stdout, linux.TIOCGWINSZ, transmute(uintptr)(&winsz))
		if ret < 0 {break}
		if winsz.x != 0 && winsz.y != 0 {break}
		time.sleep(time.Duration(10 * i) * time.Millisecond)
	}
	if winsz.x == 0 || winsz.y == 0 {
		winsz.y = 80
		winsz.x = 24
	}
	return winsz.yx
}
to_timespec :: proc(d: time.Duration) -> linux.Time_Spec {
	return {cast(uint)(d / time.Second), cast(uint)(d % time.Second)}
}
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:terminal"
import "core:terminal/ansi"
import "core:time"
