#!/usr/bin/env python3
"""Mock OpenAI-compatible chat-completions server for FnVoice tests and manual Settings testing.

Behaviour is chosen by the request's `model`:
  echo       return the transcript unchanged (default)
  fix        apply known ASR fixes (配森→Python, 杰森→JSON, ...)
  wrapped    like fix, but wrapped as  修正后：“...”  (tests output sanitizing)
  rewrite    return an unrelated polished paragraph (tests the edit guardrail)
  slow       sleep 3s, then echo (tests the client timeout)
  malformed  return a non-JSON body
  http500    return HTTP 500
Requires `Authorization: Bearer test-key`, otherwise 401.
GET /last returns the last request (headers + JSON body) for assertions.

Usage: server.py [--port 0]   prints the bound port on the first stdout line.
"""
import argparse
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = "test-key"
FIXES = {"配森": "Python", "杰森": "JSON", "加瓦": "Java", "吉特哈布": "GitHub"}
LAST = {}


def transcript_of(body):
    content = body.get("messages", [{}])[-1].get("content", "")
    m = re.search(r"<transcript>\n?(.*?)\n?</transcript>", content, re.S)
    return m.group(1) if m else content


def fix(text):
    for wrong, right in FIXES.items():
        text = text.replace(wrong, right)
    return text


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/last":
            self.send_json(200, LAST)
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        LAST.clear()
        LAST.update({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body})

        if not self.path.endswith("/chat/completions"):
            return self.send_json(404, {"error": "not found"})
        if self.headers.get("Authorization") != f"Bearer {API_KEY}":
            return self.send_json(401, {"error": {"message": "invalid api key"}})

        model = body.get("model", "echo")
        text = transcript_of(body)
        if model == "slow":
            time.sleep(3)
            content = text
        elif model == "malformed":
            data = b"<html>not json</html>"
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        elif model == "http500":
            return self.send_json(500, {"error": "boom"})
        elif model == "rewrite":
            content = "总而言之，这是一段经过全面润色和重写的文字，与原始内容已经没有太大关系了。"
        elif model == "wrapped":
            content = f"修正后：“{fix(text)}”"
        elif model == "fix":
            content = fix(text)
        else:
            content = text

        self.send_json(200, {
            "id": "mock-1",
            "object": "chat.completion",
            "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        })


def exit_with_parent():
    parent = os.getppid()
    while True:
        time.sleep(0.5)
        if os.getppid() != parent:
            os._exit(0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(server.server_address[1], flush=True)
    print(f"mock LLM on http://127.0.0.1:{server.server_address[1]}/v1  (API key: {API_KEY})", file=sys.stderr, flush=True)
    threading.Thread(target=exit_with_parent, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
