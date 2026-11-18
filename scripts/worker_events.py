# SPDX-License-Identifier: GPL-3.0-or-later
"""Mac worker-test events. Deadlines only abort a missing event; never satisfy one."""
import json
import os
import select
import time

OWNER_TICK_FD = 'CASSINI_TEST_OWNER_TICK_FD'
ENGINE_READY_FD = 'CASSINI_TEST_ENGINE_READY_FD'


def _read(fd, count, deadline):
    ready, _, _ = select.select([fd], [], [], max(0, deadline-time.monotonic()))
    if not ready:
        raise TimeoutError('Worker event did not arrive')
    data = os.read(fd, count)
    if not data:
        raise EOFError('Worker event pipe closed')
    return data


def json_line(stream, timeout=60, maximum=1 << 20):
    data = bytearray(); deadline = time.monotonic()+timeout
    while not data.endswith(b'\n'):
        if len(data) >= maximum:
            raise ValueError('Worker response exceeded its limit')
        data.extend(_read(stream.fileno(), 1, deadline))
    return json.loads(data)


def engine_ready(fd, timeout=60):
    if _read(fd, 1, time.monotonic()+timeout) != bytes([1]):
        raise ValueError('Invalid engine-ready acknowledgement')


def discard_ticks(fd):
    # Drain tokens already queued before inference finished; do not wait or poll
    # for a future state. The subsequent read requires two NEW callback events.
    while select.select([fd], [], [], 0)[0]:
        if os.read(fd, 4096) == b'':
            raise EOFError('Owner watchdog probe closed')


def watchdog_ticks(fd, count=2, timeout=60):
    seen = bytearray(); deadline = time.monotonic()+timeout
    while len(seen) < count:
        seen.extend(_read(fd, count-len(seen), deadline))
    if seen != bytes([1])*count:
        raise ValueError('Invalid watchdog callback acknowledgement')


class ProcessExit:
    """Bind NOTE_EXIT to the live process BEFORE causing owner death."""
    def __init__(self, pid):
        self.pid = pid
        self.queue = select.kqueue()
        try:
            self.queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 0, 0)
        except BaseException:
            self.queue.close(); raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.queue.close()

    def wait(self, timeout=30):
        events = self.queue.control(None, 1, timeout)
        if not events:
            raise TimeoutError('Worker survived owner death with stdin held open')
        event = events[0]
        if event.flags & select.KQ_EV_ERROR:
            raise OSError(event.data, 'Worker exit observation failed')
        if event.ident != self.pid or event.filter != select.KQ_FILTER_PROC or not event.fflags & select.KQ_NOTE_EXIT:
            raise RuntimeError('Unexpected worker process event')


def exercise_live_windows(command, environment, fixture):
    """Both native workers keep their model loaded across valid and rejected PCM requests."""
    import base64
    import struct
    import subprocess
    import wave

    with wave.open(str(fixture), 'rb') as source:
        assert (source.getnchannels(), source.getsampwidth(), source.getframerate()) == (1, 2, 16_000)
        audio = source.readframes(8 * 16_000)
    values = [value / 32768 for value, in struct.iter_unpack('<h', audio)]
    pcm = base64.b64encode(struct.pack(f'<{len(values)}f', *values)).decode('ascii')
    frames = [dict(id=1, pcm=pcm), dict(id=2, pcm='AAAA'), dict(id=3, pcm=pcm)]
    payload = ''.join(json.dumps(request) + '\n' for request in frames).encode()
    result = subprocess.run(command, input=payload, capture_output=True, env=environment, timeout=120)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    ready, first, rejected, last = [json.loads(line) for line in result.stdout.splitlines()]
    assert ready == dict(ready=True)
    assert not first['failed'] and first['id'] == 1 and first['transcript']['words']
    assert rejected['failed'] and rejected['id'] == 2
    assert not last['failed'] and last['id'] == 3
    assert first['transcript'] == last['transcript']
