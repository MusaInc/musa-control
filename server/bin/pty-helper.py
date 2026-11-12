#!/usr/bin/env python3
# Gives a command a real pseudo-terminal for Musa Control's WebSocket
# terminal (machines reached through the relay, which have no SSH from the
# iPad). stdin/stdout carry terminal bytes; fd 3 carries "cols rows" lines
# to resize. Usage: pty-helper.py COLS ROWS command [args...]
import fcntl, os, pty, select, signal, struct, sys, termios

def winsize(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def main():
    cols, rows, argv = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(argv[0], argv)
    winsize(fd, cols, rows)
    ctl = 3
    buf = b""
    inputs = [0, fd, ctl]
    try:
        while True:
            r, _, _ = select.select(inputs, [], [])
            if fd in r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                os.write(1, data)
            if 0 in r:
                data = os.read(0, 65536)
                if not data:
                    break
                os.write(fd, data)
            if ctl in r:
                data = os.read(ctl, 1024)
                if not data:
                    inputs.remove(ctl)
                    continue
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        c, rr = (int(x) for x in line.split())
                        winsize(fd, max(10, min(c, 1000)), max(4, min(rr, 500)))
                        os.kill(pid, signal.SIGWINCH)
                    except Exception:
                        pass
    finally:
        try:
            os.kill(pid, signal.SIGHUP)
        except Exception:
            pass

if __name__ == "__main__":
    main()
