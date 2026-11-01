"""HDMI-CEC app: the single owner of the Pi's CEC adapter.

The vc4 adapter has one logical address, so only one client can usefully
configure it. This daemon takes it exclusively (Linux CEC API, no libcec),
answers the TV as an Audio System or a Playback device, turns the TV's volume
keys into Home Assistant events, and serves a small HTTP API on 127.0.0.1 for
Home Assistant and other apps:

  GET  /status         adapter state as JSON
  POST /tv/on          <Image View On> to the TV
  POST /tv/off         <Standby> to the TV
  POST /active_source  wake the TV and switch it to this HDMI input

Some TVs (seen on a Hisense) ignore <Active Source> unless it comes from a
playback address. As an Audio System, /active_source borrows one: the address
is re-registered as Playback, the switch is sent, and the Audio System is
registered again, all on this daemon's own file handle.
"""

import fcntl
import json
import logging
import os
import queue
import select
import struct
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OPTIONS = "/data/options.json"
API_HOST = "127.0.0.1"
API_PORT = 8686

log = logging.getLogger("hdmi_cec")


# --- Linux CEC API (include/uapi/linux/cec.h) ---------------------------------
def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (ord("a") << 8) | nr


# struct cec_log_addrs: 92 bytes. struct cec_msg: 56. struct cec_event: 80.
LOG_ADDRS_FMT = "<4BH2BII15s4B4B4B48sx"
MSG_FMT = "<QQ4I16s7Bx"
EVENT_FMT = "<QII64s"

CEC_ADAP_G_PHYS_ADDR = _ioc(2, 1, 2)
CEC_ADAP_G_LOG_ADDRS = _ioc(2, 3, struct.calcsize(LOG_ADDRS_FMT))
CEC_ADAP_S_LOG_ADDRS = _ioc(3, 4, struct.calcsize(LOG_ADDRS_FMT))
CEC_TRANSMIT = _ioc(3, 5, struct.calcsize(MSG_FMT))
CEC_RECEIVE = _ioc(3, 6, struct.calcsize(MSG_FMT))
CEC_DQEVENT = _ioc(3, 7, struct.calcsize(EVENT_FMT))
CEC_S_MODE = _ioc(1, 9, 4)

# Exclusive initiator and follower: no other client can reconfigure the
# adapter or steal its messages. The core still answers the basic queries
# (physical address, OSD name, vendor ID, CEC version) itself.
CEC_MODE_EXCL_INITIATOR = 0x02
CEC_MODE_EXCL_FOLLOWER = 0x20

CEC_EVENT_STATE_CHANGE = 1
CEC_EVENT_LOST_MSGS = 2
CEC_TX_STATUS_OK = 0x01
CEC_RX_STATUS_OK = 0x01
CEC_VERSION_1_4 = 5
CEC_PHYS_ADDR_INVALID = 0xFFFF
CEC_LOG_ADDR_INVALID = 0xFF
BROADCAST = 0x0F
TV = 0x00

# device_type option -> (primary device type, logical address type)
DEVICE_TYPES = {
    "audio_system": (5, 4),
    "playback": (4, 3),
}

MSG_IMAGE_VIEW_ON = 0x04
MSG_STANDBY = 0x36
MSG_USER_CONTROL_PRESSED = 0x44
MSG_SYSTEM_AUDIO_MODE_REQUEST = 0x70
MSG_GIVE_AUDIO_STATUS = 0x71
MSG_SET_SYSTEM_AUDIO_MODE = 0x72
MSG_REPORT_AUDIO_STATUS = 0x7A
MSG_GIVE_SYSTEM_AUDIO_MODE_STATUS = 0x7D
MSG_SYSTEM_AUDIO_MODE_STATUS = 0x7E
MSG_ACTIVE_SOURCE = 0x82
MSG_REQUEST_ACTIVE_SOURCE = 0x85
MSG_GIVE_DEVICE_POWER_STATUS = 0x8F
MSG_REPORT_POWER_STATUS = 0x90
POWER_ON = 0x00

# After a wake, how long to wait for the TV to come up, and how long to keep
# answering its <Request Active Source> with a switch to this input.
TV_WAKE_TIMEOUT = 20
ACTIVE_SOURCE_CLAIM = 30

UI_KEYS = {0x41: "volume_up", 0x42: "volume_down", 0x43: "mute_toggle"}
VOLUME_STEP = 5


def format_pa(pa):
    return "f.f.f.f" if pa == CEC_PHYS_ADDR_INVALID else ".".join(
        f"{(pa >> s) & 0xF:x}" for s in (12, 8, 4, 0))


class Adapter:
    """One open file handle on /dev/cecN."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDWR)
        try:
            fcntl.ioctl(self.fd, CEC_S_MODE,
                        struct.pack("<I", CEC_MODE_EXCL_INITIATOR | CEC_MODE_EXCL_FOLLOWER))
        except OSError:
            os.close(self.fd)
            raise

    def phys_addr(self):
        buf = bytearray(2)
        fcntl.ioctl(self.fd, CEC_ADAP_G_PHYS_ADDR, buf)
        return struct.unpack("<H", buf)[0]

    def log_addr(self):
        buf = bytearray(struct.calcsize(LOG_ADDRS_FMT))
        fcntl.ioctl(self.fd, CEC_ADAP_G_LOG_ADDRS, buf)
        fields = struct.unpack(LOG_ADDRS_FMT, buf)
        num_log_addrs = fields[6]
        return fields[0] if num_log_addrs else CEC_LOG_ADDR_INVALID

    def configure(self, device_type, osd_name, vendor_id):
        """Clear the logical addresses, then claim one of device_type.

        The handle is blocking, so this returns once the address is claimed,
        or at once if the TV gives no physical address (the core claims it
        when one appears).
        """
        fcntl.ioctl(self.fd, CEC_ADAP_S_LOG_ADDRS,
                    bytearray(struct.calcsize(LOG_ADDRS_FMT)))
        prim, la_type = DEVICE_TYPES[device_type]
        buf = bytearray(struct.pack(
            LOG_ADDRS_FMT,
            CEC_LOG_ADDR_INVALID, CEC_LOG_ADDR_INVALID,
            CEC_LOG_ADDR_INVALID, CEC_LOG_ADDR_INVALID,
            0, CEC_VERSION_1_4, 1, vendor_id, 0,
            osd_name.encode()[:14],
            prim, 0, 0, 0, la_type, 0, 0, 0, 0, 0, 0, 0, b"\0" * 48))
        fcntl.ioctl(self.fd, CEC_ADAP_S_LOG_ADDRS, buf)
        return self.log_addr()

    def transmit(self, dest, opcode, params=b""):
        src = self.log_addr()
        if src == CEC_LOG_ADDR_INVALID:
            log.warning("not sending 0x%02x: no logical address", opcode)
            return False
        payload = bytes([(src << 4) | dest, opcode]) + bytes(params)
        buf = bytearray(struct.pack(MSG_FMT, 0, 0, len(payload), 0, 0, 0,
                                    payload, 0, 0, 0, 0, 0, 0, 0))
        try:
            fcntl.ioctl(self.fd, CEC_TRANSMIT, buf)
        except OSError as e:
            log.warning("sending 0x%02x to %d failed: %s", opcode, dest, e)
            return False
        tx_status = struct.unpack(MSG_FMT, buf)[9]
        # A broadcast is never acknowledged, so only a directed NACK is an error.
        ok = bool(tx_status & CEC_TX_STATUS_OK) or dest == BROADCAST
        log.debug("tx %x->%x 0x%02x %s status 0x%02x", src, dest, opcode,
                  bytes(params).hex(), tx_status)
        return ok

    def power_status(self, dest=TV):
        """Ask dest for its power status; None if it doesn't answer.

        The core waits for <Report Power Status> itself (reply + timeout),
        so the answer never reaches the follower loop.
        """
        src = self.log_addr()
        if src == CEC_LOG_ADDR_INVALID:
            return None
        payload = bytes([(src << 4) | dest, MSG_GIVE_DEVICE_POWER_STATUS])
        buf = bytearray(struct.pack(MSG_FMT, 0, 0, len(payload), 1000, 0, 0,
                                    payload, MSG_REPORT_POWER_STATUS, 0, 0, 0, 0, 0, 0))
        try:
            fcntl.ioctl(self.fd, CEC_TRANSMIT, buf)
        except OSError:
            return None
        fields = struct.unpack(MSG_FMT, buf)
        length, msg, rx_status = fields[2], fields[6], fields[8]
        if not rx_status & CEC_RX_STATUS_OK or length < 3:
            return None
        return msg[2]

    def receive(self):
        buf = bytearray(struct.calcsize(MSG_FMT))
        fcntl.ioctl(self.fd, CEC_RECEIVE, buf)
        fields = struct.unpack(MSG_FMT, buf)
        length, msg = fields[2], fields[6]
        if length < 2:
            return None  # a poll message
        return msg[0] >> 4, msg[0] & 0xF, msg[1], msg[2:length]

    def event(self):
        buf = bytearray(struct.calcsize(EVENT_FMT))
        fcntl.ioctl(self.fd, CEC_DQEVENT, buf)
        _, kind, _, data = struct.unpack(EVENT_FMT, buf)
        return kind, data


class HomeAssistant:
    """Fires events on Home Assistant's bus through the Supervisor proxy.

    A worker thread posts them so a slow Core never delays a CEC reply.
    """

    def __init__(self, event_type):
        self.url = f"http://supervisor/core/api/events/{event_type}"
        self.token = os.environ.get("SUPERVISOR_TOKEN")
        self.events = queue.Queue()
        if not self.token:
            log.warning("no SUPERVISOR_TOKEN; Home Assistant events are off")
        threading.Thread(target=self._post_events, daemon=True).start()

    def fire(self, data):
        if self.token:
            self.events.put(data)

    def _post_events(self):
        while True:
            data = self.events.get()
            req = urllib.request.Request(
                self.url, data=json.dumps(data).encode(), method="POST",
                headers={"Authorization": f"Bearer {self.token}",
                         "Content-Type": "application/json"})
            try:
                urllib.request.urlopen(req, timeout=5).close()
            except OSError as e:
                log.warning("firing %s failed: %s", data, e)


class Cec:
    def __init__(self, options):
        self.device_type = options["device_type"]
        self.osd_name = options["osd_name"][:14]
        # Raspberry Pi Foundation's IEEE OUI, as cec_audio and cec-ctl use.
        self.vendor_id = 0x000C03
        self.adapter = Adapter(options["device"])
        self.ha = HomeAssistant(options["event_type"])
        # Volume as the TV is told it. The real volume lives wherever the
        # events are handled (e.g. a DSP), so this only keeps the TV's
        # on-screen bar moving.
        self.volume = 50
        self.muted = False
        # Held while the address is borrowed, so requests don't interleave.
        self.lock = threading.Lock()
        # Until then, the TV's <Request Active Source> gets this input.
        self.claim_until = 0
        la = self.adapter.configure(self.device_type, self.osd_name, self.vendor_id)
        log.info("%s: %s \"%s\", logical address %s, physical address %s",
                 self.adapter.path, self.device_type, self.osd_name,
                 "none yet" if la == CEC_LOG_ADDR_INVALID else la,
                 format_pa(self.adapter.phys_addr()))

    def status(self):
        la = self.adapter.log_addr()
        return {
            "device": self.adapter.path,
            "device_type": self.device_type,
            "osd_name": self.osd_name,
            "logical_address": None if la == CEC_LOG_ADDR_INVALID else la,
            "physical_address": format_pa(self.adapter.phys_addr()),
        }

    # --- requests ---------------------------------------------------------
    def tv_on(self):
        with self.lock:
            return self.adapter.transmit(TV, MSG_IMAGE_VIEW_ON)

    def tv_off(self):
        with self.lock:
            return self.adapter.transmit(TV, MSG_STANDBY)

    def active_source(self):
        with self.lock:
            self.claim_until = time.monotonic() + ACTIVE_SOURCE_CLAIM
            ready = self.tv_ready(self.adapter.power_status())
            woke = self.adapter.transmit(TV, MSG_IMAGE_VIEW_ON)
            if not ready:
                self.wait_for_tv(woke)
            return self.switch_input()

    def tv_ready(self, power):
        """The TV is on and both our addresses are valid.

        A TV that doesn't answer <Give Device Power Status> counts as on, so
        it isn't kept waiting for an answer that never comes.
        """
        return (power in (POWER_ON, None)
                and self.adapter.phys_addr() != CEC_PHYS_ADDR_INVALID
                and self.adapter.log_addr() != CEC_LOG_ADDR_INVALID)

    def wait_for_tv(self, woke):
        """Wait for a TV that was off or booting to come up.

        A Hisense drops the hot-plug signal while it boots, which takes the
        Pi's physical and logical addresses away, and it ignores an
        <Active Source> that arrives before it is up.
        """
        start = time.monotonic()
        while time.monotonic() - start < TV_WAKE_TIMEOUT:
            time.sleep(0.5)
            if not woke and self.adapter.log_addr() != CEC_LOG_ADDR_INVALID:
                # The first <Image View On> had no address to go out from.
                woke = self.adapter.transmit(TV, MSG_IMAGE_VIEW_ON)
            if self.tv_ready(self.adapter.power_status()) and woke:
                log.info("TV up after %.1fs", time.monotonic() - start)
                # It reports On a moment before it acts on input changes.
                time.sleep(1)
                return
        log.warning("TV not up after %ds; switching anyway", TV_WAKE_TIMEOUT)

    def switch_input(self):
        pa = self.adapter.phys_addr()
        if pa == CEC_PHYS_ADDR_INVALID:
            return {"ok": False, "error": "no physical address"}
        borrowed = self.device_type != "playback"
        if borrowed:
            self.adapter.configure("playback", self.osd_name, self.vendor_id)
        ok = self.adapter.transmit(BROADCAST, MSG_ACTIVE_SOURCE, pa.to_bytes(2, "big"))
        if borrowed:
            # Give the TV time to act on it before the address goes away.
            time.sleep(0.5)
            self.adapter.configure(self.device_type, self.osd_name, self.vendor_id)
        log.info("switched TV to this input (%s)%s", format_pa(pa),
                 " from a borrowed playback address" if borrowed else "")
        return {"ok": ok, "physical_address": format_pa(pa), "borrowed": borrowed}

    def answer_request_active_source(self):
        with self.lock:
            self.switch_input()

    # --- the TV's messages ------------------------------------------------
    def report_audio_status(self, dest):
        self.adapter.transmit(dest, MSG_REPORT_AUDIO_STATUS,
                              [(self.volume & 0x7F) | (0x80 if self.muted else 0)])

    def handle(self, src, dest, opcode, params):
        log.debug("rx %x->%x 0x%02x %s", src, dest, opcode, params.hex())
        audio = self.device_type == "audio_system"
        if opcode == MSG_USER_CONTROL_PRESSED and params:
            action = UI_KEYS.get(params[0])
            if not action:
                return
            if action == "volume_up":
                self.volume, self.muted = min(100, self.volume + VOLUME_STEP), False
            elif action == "volume_down":
                self.volume, self.muted = max(0, self.volume - VOLUME_STEP), False
            else:
                self.muted = not self.muted
            log.info("key: %s", action)
            self.ha.fire({"action": action})
            if audio:
                self.report_audio_status(src)
        elif opcode == MSG_REQUEST_ACTIVE_SOURCE:
            # A TV that has just booted asks who the source is, and may
            # ignore a switch that came earlier.
            if time.monotonic() < self.claim_until:
                log.info("TV asked for the active source")
                threading.Thread(target=self.answer_request_active_source,
                                 daemon=True).start()
        elif opcode == MSG_GIVE_DEVICE_POWER_STATUS:
            self.adapter.transmit(src, MSG_REPORT_POWER_STATUS, [0x00])
        elif not audio:
            return
        elif opcode == MSG_GIVE_AUDIO_STATUS:
            self.report_audio_status(src)
        elif opcode == MSG_SYSTEM_AUDIO_MODE_REQUEST:
            self.adapter.transmit(BROADCAST, MSG_SET_SYSTEM_AUDIO_MODE, [0x01])
            self.report_audio_status(src)
        elif opcode == MSG_GIVE_SYSTEM_AUDIO_MODE_STATUS:
            self.adapter.transmit(src, MSG_SYSTEM_AUDIO_MODE_STATUS, [0x01])

    def run(self):
        fd = self.adapter.fd
        while True:
            readable, _, exceptional = select.select([fd], [], [fd])
            if exceptional:
                kind, data = self.adapter.event()
                if kind == CEC_EVENT_STATE_CHANGE:
                    pa, la_mask = struct.unpack_from("<HH", data)
                    log.info("adapter state: physical address %s, logical addresses 0x%04x",
                             format_pa(pa), la_mask)
                elif kind == CEC_EVENT_LOST_MSGS:
                    log.warning("lost %d messages", struct.unpack_from("<I", data)[0])
            if readable:
                msg = self.adapter.receive()
                if msg:
                    try:
                        self.handle(*msg)
                    except OSError as e:
                        log.warning("handling %s failed: %s", msg, e)


def serve_api(cec):
    routes = {
        ("GET", "/status"): cec.status,
        ("POST", "/tv/on"): lambda: {"ok": cec.tv_on()},
        ("POST", "/tv/off"): lambda: {"ok": cec.tv_off()},
        ("POST", "/active_source"): cec.active_source,
    }

    class Handler(BaseHTTPRequestHandler):
        def _route(self, method):
            route = routes.get((method, self.path.rstrip("/")))
            if not route:
                return self._reply(404, {"error": "not found"})
            try:
                result = route()
            except OSError as e:
                log.warning("%s %s failed: %s", method, self.path, e)
                return self._reply(500, {"ok": False, "error": str(e)})
            self._reply(200 if result.get("ok", True) else 502, result)

        def _reply(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._route("GET")

        def do_POST(self):
            self._route("POST")

        def log_message(self, fmt, *args):
            log.debug("api: " + fmt, *args)

    server = ThreadingHTTPServer((API_HOST, API_PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info("API on http://%s:%d", API_HOST, API_PORT)


def main():
    with open(OPTIONS) as f:
        options = json.load(f)
    logging.basicConfig(
        level=logging.DEBUG if options.get("debug") else logging.INFO,
        format="[hdmi_cec] %(levelname)s %(message)s")
    while True:
        try:
            cec = Cec(options)
            break
        except OSError as e:
            # EBUSY while another client (e.g. a Home Assistant integration
            # being shut down) still holds the adapter exclusively.
            log.warning("can't take %s: %s; retrying in 5s", options["device"], e)
            time.sleep(5)
    serve_api(cec)
    cec.run()


if __name__ == "__main__":
    main()
