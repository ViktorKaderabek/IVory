"""The iPhone screen as a video stream: WebDriverAgent serves MJPEG on a forwarded port, and this keeps
the latest frame of it. Without the stream the bot falls back to screenshots, which are much slower."""
import re
import socket
import threading
import time

from . import config as cfg


# --- Phone screen ---
# --- Phone screen ---
class Stream:
    """Reads the WebDriverAgent MJPEG stream and keeps the latest frame."""

    def __init__(self, port):
        self.port = port
        self.lock = threading.Lock()
        self.jpeg, self.t, self.n = None, 0.0, 0
        self.stop_ev = threading.Event()
        if cfg.USE_STREAM:
            threading.Thread(target=self._run, daemon=True).start()

    def latest(self):
        with self.lock:
            return self.jpeg, self.t, self.n

    def fresh(self, age=0.6):
        return self.jpeg is not None and time.time() - self.t < age

    def _run(self):
        while not self.stop_ev.is_set():
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=3) as s:
                    s.settimeout(5)
                    s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                    buf = bytearray()
                    while not self.stop_ev.is_set():
                        chunk = s.recv(1 << 18)
                        if not chunk:
                            break
                        buf += chunk
                        self._frames(buf)
            except OSError:
                pass
            self.stop_ev.wait(1.0)

    def _frames(self, buf):
        while True:
            i = buf.find(b"\xff\xd8")
            if i < 0:
                if len(buf) > 1 << 16:
                    del buf[:-1024]
                return
            m = re.search(rb"Content-Length:\s*(\d+)", bytes(buf[max(0, i - 256):i]), re.I)
            if m:
                end = i + int(m.group(1))
                if len(buf) < end:
                    return
            else:
                j = buf.find(b"\xff\xd9", i + 2)
                if j < 0:
                    return
                end = j + 2
            frame = bytes(buf[i:end])
            del buf[:end]
            with self.lock:
                self.jpeg, self.t, self.n = frame, time.time(), self.n + 1
