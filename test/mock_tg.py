#!/usr/bin/env python3
# Minimal mock Telegram Bot API for llm2ssh end-to-end tests. Serves getMe /
# getUpdates (delivers one /start from @tester once) / sendMessage (logged), so
# the REAL `bot setup` handshake and the REAL daemon can be exercised offline.
import http.server, json, urllib.parse, time

LOG = "/tmp/mock_sends.log"
STATE = {"start_delivered": False}


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass

    def do_POST(self):
        self._route()

    def do_GET(self):
        self._route()

    def _route(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode() if n else ""
        method = self.path.rsplit("/", 1)[-1].split("?")[0]
        p = urllib.parse.parse_qs(body)
        if method == "getMe":
            return self._send({"ok": True, "result": {"id": 1, "username": "testbot", "is_bot": True}})
        if method == "deleteWebhook":
            return self._send({"ok": True, "result": True})
        if method == "getUpdates":
            offset = int(p.get("offset", ["0"])[0])
            if not STATE["start_delivered"] and offset <= 100:
                STATE["start_delivered"] = True
                return self._send({"ok": True, "result": [{
                    "update_id": 100,
                    "message": {"message_id": 5, "text": "/start",
                                "chat": {"id": 42, "type": "private"},
                                "from": {"id": 42, "username": "tester", "is_bot": False}}}]})
            time.sleep(1)  # simulate long-poll so the daemon doesn't busy-spin
            return self._send({"ok": True, "result": []})
        if method in ("sendMessage", "sendChatAction", "editMessageText",
                      "answerCallbackQuery", "sendDocument"):
            with open(LOG, "a") as f:
                f.write(method + " " + body + "\n")
            return self._send({"ok": True, "result": {"message_id": 6}})
        return self._send({"ok": True, "result": {}})


http.server.ThreadingHTTPServer(("127.0.0.1", 8081), H).serve_forever()
