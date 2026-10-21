#!/usr/bin/env python3
"""Local stand-in for an OpenAI-compatible API, for testing ScreenLocalizer without a key or credits.

    python3 -I scripts/mock-openai.py [port] [request-log.jsonl]

Point the app at it: Settings → AI → Provider "Custom", base URL http://127.0.0.1:<port>/v1.
Special model names: "fail-401" returns an auth error; "fail-param" rejects `temperature` once
(exercising the client's retry without tuning parameters).
"""
import io
import json
import math
import struct
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
LOG = sys.argv[2] if len(sys.argv) > 2 else None

REPLIES = {
    "translate": "يتميّز **Orion 2** بنافذة سياق (Context Window) تصل إلى مليون توكن، ويحقق 94.2% في اختبار GPQA Diamond.\n\nكما تتحسن المهام الطويلة بشكل كبير.",
    "explain": "الجديد هنا نقطتان مهمتان:\n\n- **نافذة سياق بمليون توكن**: يعني الموديل يقدر يقرأ مشروعًا كاملًا مرة واحدة.\n- **أداء أعلى في الاستدلال**: نتيجة 94.2% في GPQA تعني فهمًا أعمق للأسئلة العلمية الصعبة.\n\nلماذا يهمك؟ لأن أدوات البرمجة ستصبح أذكى وأسرع.",
    "simplify": "تخيّل أن الموديل عنده ذاكرة ضخمة تشبه مكتبة كاملة يقرأها مرة واحدة 📚. هذا يعني أنه يفهم الصورة الكاملة قبل أن يجيبك.",
    "summarize": "- نافذة سياق بمليون توكن\n- 94.2% في GPQA Diamond\n- تدخلات أقل بثلاث مرات في جلسات البرمجة\n- موثوقية 99.1% في استدعاء الأدوات",
    "script": "خبر كبير في عالم الذكاء الاصطناعي!\n\nأُطلق اليوم Orion 2، وأهم ما فيه أنه يقدر يقرأ مشروعك كله دفعة واحدة.\n\nوهذا يعني لك كمبرمج أن الأخطاء ستقل، والوقت سيختصر.\n\nتعالوا نشوف التفاصيل.",
    "post": "**تغريدة X:**\nOrion 2 وصل 🚀 مليون توكن سياق و94.2% في GPQA — البرمجة مع الذكاء الاصطناعي دخلت مرحلة جديدة. #AI\n\n**منشور LinkedIn:**\nأُطلق Orion 2 اليوم بنافذة سياق تصل إلى مليون توكن، مما يسمح بفهم مشاريع كاملة دفعة واحدة.",
    "followup": "سؤال ممتاز! الفرق الأساسي أن **التوكن** وحدة نص صغيرة، ومليون توكن تعادل تقريبًا 750 ألف كلمة إنجليزية.",
}


def detect_mode(messages):
    system = next((m["content"] for m in messages if m["role"] == "system"), "")
    if "follow-up questions" in system and messages[-1]["role"] == "user" and len(messages) > 2:
        return "followup"
    checks = [
        ("Translate the user's text", "translate"),
        ("EXPLAIN it", "explain"),
        ("very simple", "simplify"),
        ("Summarize the user's text", "summarize"),
        ("spoken script", "script"),
        ("social media", "post"),
    ]
    for needle, mode in checks:
        if needle in system:
            return mode
    return "translate"


def sine_wav(seconds=0.6, freq=440):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        frames = b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * freq * i / 22050)))
                          for i in range(int(22050 * seconds)))
        w.writeframes(frames)
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    rejected_param_once = False

    def log_message(self, fmt, *args):
        pass

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log(self, entry):
        if LOG:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._log({"path": self.path, "auth": self.headers.get("Authorization", "")})
            self._json(200, {"object": "list", "data": [{"id": m} for m in ["gpt-4o-mini", "gpt-5-mini", "gpt-5-nano", "text-embedding-3-small"]]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        self._log({"path": self.path, "auth": self.headers.get("Authorization", ""), "body": body})

        if self.path.endswith("/audio/speech"):
            data = sine_wav()
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if not self.path.endswith("/chat/completions"):
            self._json(404, {"error": {"message": "unknown endpoint"}})
            return

        model = body.get("model", "")
        if model == "fail-401":
            self._json(401, {"error": {"message": "Incorrect API key provided: sk-test***", "type": "invalid_request_error"}})
            return
        if model == "fail-param" and "temperature" in body:
            self._json(400, {"error": {"message": "Unsupported parameter: 'temperature' is not supported with this model."}})
            return

        reply = REPLIES[detect_mode(body.get("messages", []))]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        words = reply.split(" ")
        try:
            for i, word in enumerate(words):
                chunk = word + (" " if i < len(words) - 1 else "")
                event = {"id": "mock", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": chunk}}]}
                self.wfile.write(f"data: {json.dumps(event, ensure_ascii=False)}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.025)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except BrokenPipeError:
            pass
        self.close_connection = True


if __name__ == "__main__":
    print(f"mock OpenAI API on http://127.0.0.1:{PORT}/v1", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
