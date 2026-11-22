"""Local-only 易灵绘 Agent demo. All device effects are software simulations."""
import argparse
import copy
import json
import os
import secrets
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, urlsplit
import urllib.error
import urllib.request

import core
import provider
from gateway import Transport

ROOT = Path(__file__).resolve().parent
WEB = ROOT / "web"
SNAPSHOT_URL = "http://127.0.0.1:8080/snapshot.jpg"
MAX_BODY = 65_536  # 识图请求携带 base64 帧


class Conflict(core.Invalid):
    """Optimistic revision conflict; caller must reconcile and review again."""


class App:
    def __init__(self, gateway=None, api_key="", model="deepseek-flash", mode="deepseek"):
        self.transport = Transport(gateway, os.environ.get("AGENT_GATEWAY_SECRET", ""))
        self.lock = threading.RLock()
        self.api_key, self.model, self.mode = api_key, model, "deepseek"
        self.history = []
        self.state, self.revision, self.boot_id = None, None, None
        self.state_known = False
        self.scene = None  # 最近一次画面分析摘要（中文文本）
        self.scene_stats = None
        self.scene_image = None  # 最近一帧 base64（仅内存）
        self.send_image = True
        self.last_trace = ["云 Agent 就绪（状态为软件模拟）"]
        try:
            self.refresh()
        except core.Invalid:
            self.last_trace = ["网关状态不可用；请显式刷新后再操作"]

    def snapshot(self):
        return {"state": copy.deepcopy(self.state) if self.state_known else None,
                "state_known": self.state_known, "revision": self.revision, "boot_id": self.boot_id,
                "mode": "deepseek", "model": self.model, "connected": bool(self.api_key),
                "simulation": True, "trace": list(self.last_trace), "capabilities": core.capabilities(),
                "scene": self.scene, "send_image": self.send_image,
                "scene_image_ready": self.scene_image is not None}

    def refresh(self):
        try:
            status = self.transport.request("status")
        except Exception as exc:
            self.state_known = False
            self.last_trace = ["状态读回失败；当前状态未知"]
            raise core.Invalid("状态读回失败，当前模拟状态未知；请重试刷新。") from exc
        self.state, self.revision, self.boot_id = status["state"], status["revision"], status["boot_id"]
        self.state_known = True
        self.last_trace = [f"已从网关读回状态 revision {self.revision}"]
        return self.snapshot()

    def check_revision(self, revision):
        if type(revision) is not int:
            raise core.Invalid("revision 必须是整数")
        if not self.state_known:
            raise core.Invalid("当前状态未知；刷新成功后才能继续操作")
        if revision != self.revision:
            raise Conflict("状态版本已变化；请检查已读回状态并重新提交")

    def control(self, changes, expected_revision):
        self.check_revision(expected_revision)
        patch = core.validate_patch(changes)
        try:
            reply = self.transport.request("apply", changes=patch, revision=self.revision, boot_id=self.boot_id)
        except (core.Invalid, OSError) as exc:
            try:
                self.refresh()
            except core.Invalid:
                raise core.Invalid(f"{exc} 状态读回也失败，当前状态未知。") from None
            if isinstance(exc, OSError):
                raise Conflict(f"网关传输异常：已读回当前模拟状态 revision {self.revision}；请检查后再决定是否重试。") from exc
            if "状态已改变" in str(exc):
                raise Conflict(f"{exc} 已刷新状态至 revision {self.revision}，请重新确认指令。") from None
            if "结果未知" in str(exc):
                raise Conflict(f"{exc} 已读回当前模拟状态 revision {self.revision}；请检查后再决定是否重试。") from None
            raise
        self.state, self.revision, self.boot_id = reply["state"], reply["revision"], reply["boot_id"]
        self.state_known = True
        self.last_trace = reply["trace"] or ["状态已读取"]
        return {"state": self.state, "revision": self.revision, "uart": reply["uart"], "trace": self.last_trace}

    def chat(self, text, expected_revision, image=None):
        if not isinstance(text, str) or not text.strip() or len(text) > 2000:
            raise core.Invalid("请输入 1–2000 字符的请求")
        if not self.api_key:
            raise core.Invalid("请先在连接设置中填写 DeepSeek API Key；未发送设备指令")
        if image is not None:
            if not isinstance(image, str) or not image.startswith("data:image/jpeg;base64,") or len(image) > 100_000:
                raise core.Invalid("画面帧格式无效或过大")
        with self.lock:
            self.check_revision(expected_revision)
            before = copy.deepcopy(self.state)
            original_boot_id = self.boot_id
            plan = provider.plan(text, before, self.history, self.api_key, self.model,
                                 scene=self.scene, image=image)
            plan = core.validate_plan(plan)
            # A separate client/process may have changed the gateway while inference ran.
            self.refresh()
            if self.boot_id != original_boot_id:
                raise Conflict("网关已重启；请检查当前状态并重新生成计划。")
            self.check_revision(expected_revision)
            execution = {"state": before, "revision": self.revision, "uart": None,
                         "trace": ["已生成计划；无参数需要变更"]}
            if plan["changes"]:
                execution = self.control(plan["changes"], expected_revision)
            self.last_trace = execution["trace"]
            # History only contains validated plans and the actual resulting state.
            self.history.extend([
                {"role": "user", "content": json.dumps({"request": text}, ensure_ascii=False)},
                {"role": "assistant", "content": json.dumps({"reply": plan["reply"], "changes": plan["changes"],
                                                                "resulting_state": execution["state"]}, ensure_ascii=False)},
            ])
            self.history = self.history[-16:]
            return {"plan": plan, "execution": execution, "snapshot": self.snapshot()}


def handler_factory(app):
    class Handler(BaseHTTPRequestHandler):
        server_version = "YilinghuiDemo/1"

        def log_message(self, fmt, *args):
            # Never log request bodies, headers, prompts, keys, or peer addresses.
            return

        def send(self, status, obj, content_type="application/json; charset=utf-8"):
            raw = obj if isinstance(obj, bytes) else json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(raw)

        def send_latest(self):
            try:
                with urllib.request.urlopen(SNAPSHOT_URL, timeout=5) as upstream:
                    raw = upstream.read()
            except Exception:
                self.send(503, b"no real frame\n", "text/plain; charset=utf-8")
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)

        def setup(self):
            super().setup()
            self.connection.settimeout(10)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == "/":
                self.send(200, (WEB / "index.html").read_bytes(), "text/html; charset=utf-8")
                return
            if path in ("/app.js", "/style.css"):
                mime = "text/javascript; charset=utf-8" if path.endswith("js") else "text/css; charset=utf-8"
                self.send(200, (WEB / path[1:]).read_bytes(), mime)
                return
            if path.startswith("/fonts/") and path.endswith(".woff2"):
                name = path[len("/fonts/"):]
                if name in {"plexmono-400.woff2", "plexmono-600.woff2", "plexsans-600.woff2"}:
                    self.send(200, (WEB / "fonts" / name).read_bytes(), "font/woff2")
                    return
            if path == "/real/snapshot.jpg":
                self.send_latest()
                return
            if not self.authorized():
                self.send(401, {"error": "会话未配对"})
                return
            if path == "/api/status":
                with app.lock:
                    self.send(200, app.snapshot())
            else:
                self.send(404, {"error": "未找到"})

        def authorized(self):
            # 配对令牌已按需求移除（2026-10-25）；仅保留同源校验防跨站请求
            expected = f"http://{self.headers.get('Host', '')}"
            origin = self.headers.get("Origin")
            if origin:
                return origin == expected
            referer = self.headers.get("Referer", "")
            try:
                parsed = urlsplit(referer)
                return f"{parsed.scheme}://{parsed.netloc}" == expected
            except ValueError:
                return False

        def do_POST(self):
            if not self.authorized():
                self.send(401, {"error": "会话未配对"})
                return
            length = self.headers.get("Content-Length", "")
            if not length.isdigit() or int(length) > MAX_BODY:
                self.send(413, {"error": "请求体过大或长度无效"})
                return
            try:
                data = json.loads(self.rfile.read(int(length)))
                path = urlparse(self.path).path
                if path == "/api/real-action":
                    action = data.get("action") if isinstance(data, dict) else None
                    if not isinstance(action, str) or not action or len(action) > 40:
                        raise core.Invalid("动作无效")
                    req = urllib.request.Request(
                        "http://127.0.0.1:8080/api/control/action",
                        data=json.dumps({"action": action}).encode(),
                        headers={"Content-Type": "application/json"},
                        method="POST")
                    try:
                        with urllib.request.urlopen(req, timeout=8) as resp:
                            result = json.loads(resp.read(65536))
                    except urllib.error.HTTPError as e:
                        try:
                            result = json.loads(e.read(65536))
                        except Exception:
                            result = {"ok": False, "err": f"真实控制 HTTP {e.code}"}
                    except Exception:
                        raise core.Invalid("真实控制接口不可达；板2/接收端可能未运行")
                    self.send(200, result)
                    return
                with app.lock:
                    if path == "/api/refresh":
                        result = app.refresh()
                    elif path == "/api/chat":
                        if not isinstance(data, dict):
                            raise core.Invalid("对话请求格式无效")
                        result = app.chat(data.get("text"), data.get("revision"), image=data.get("image"))
                    elif path == "/api/control":
                        if not isinstance(data, dict):
                            raise core.Invalid("控制请求格式无效")
                        result = app.control(data.get("changes"), data.get("revision"))
                    elif path == "/api/settings":
                        if not isinstance(data, dict) or data.get("mode", "deepseek") != "deepseek":
                            raise core.Invalid("仅支持 DeepSeek 云模式")
                        key, model = data.get("api_key", ""), data.get("model", app.model)
                        if not isinstance(key, str) or len(key) > 512 or not isinstance(model, str) or not 1 <= len(model) <= 80:
                            raise core.Invalid("Key 或模型名称无效")
                        app.model = model
                        if key:
                            app.api_key = key
                        elif data.get("clear_key"):
                            app.api_key = ""
                        result = app.snapshot()
                    else:
                        self.send(404, {"error": "未找到"})
                        return
                self.send(200, result)
            except Conflict as e:
                self.send(409, {"error": str(e), "snapshot": app.snapshot()})
            except core.Invalid as e:
                self.send(400, {"error": str(e), "snapshot": app.snapshot()})
            except (UnicodeDecodeError, json.JSONDecodeError):
                self.send(400, {"error": "JSON 请求格式无效"})
            except Exception:
                self.send(502, {"error": "执行失败；当前状态可能未知，请显式刷新" , "snapshot": app.snapshot()})

    return Handler


def main():
    parser = argparse.ArgumentParser(description="易灵绘软件模拟 Agent WebUI")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--gateway", help="软件 UDP 网关 host:port")
    args = parser.parse_args()
    gateway = None
    if args.gateway:
        host, port = args.gateway.rsplit(":", 1)
        if host not in ("127.0.0.1", "localhost", "::1"):
            parser.error("软件网关地址仅允许本机 loopback，不支持任意网络目标")
        if not 1 <= int(port) <= 65535:
            parser.error("网关端口范围无效")
        secret = os.environ.get("AGENT_GATEWAY_SECRET", "")
        if len(secret) < 16:
            parser.error("指定网关时 AGENT_GATEWAY_SECRET 至少需要16字符")
        gateway = (host, int(port))
    app = App(gateway, os.environ.get("DEEPSEEK_API_KEY", ""))
    httpd = ThreadingHTTPServer((args.host, args.port), handler_factory(app))
    print("Agent Studio 启动（DeepSeek 云模式；设备状态为软件模拟）。", flush=True)
    print(f"本机访问: http://127.0.0.1:{httpd.server_port}/", flush=True)
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        try:
            addresses = sorted({item[4][0] for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
                                if not item[4][0].startswith("127.")})
        except OSError:
            addresses = []
        for address in addresses:
            print(f"同局域网设备访问: http://{address}:{httpd.server_port}/", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
