"""Software-only board2 -> board1 gateway, also usable as UDP reference peer."""
import argparse
import copy
import hashlib
import hmac
import json
import os
import socket
import threading
import time
import uuid
from collections import OrderedDict
from core import DEFAULT, Invalid, capabilities, validate_patch, uart_preview


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def pack(obj, secret):
    payload = canonical(obj)
    return canonical({"payload": obj, "mac": hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()})


def unpack(data, secret):
    if len(data) > 8192:
        raise Invalid("网络包过长")
    try:
        envelope = json.loads(data)
        payload, mac = envelope["payload"], envelope["mac"]
        expected = hmac.new(secret.encode(), canonical(payload), hashlib.sha256).hexdigest()
        if not isinstance(mac, str) or not hmac.compare_digest(mac, expected):
            raise Invalid("网关认证失败")
        return payload
    except (ValueError, KeyError, TypeError):
        raise Invalid("网关信封无效") from None


class Gateway:
    def __init__(self):
        self.state = copy.deepcopy(DEFAULT)
        self.revision = 0
        self.boot_id = uuid.uuid4().hex
        self.lock = threading.Lock()
        self.seen = OrderedDict()

    def handle(self, req):
        with self.lock:
            if not isinstance(req, dict) or req.get("v") != 1:
                raise Invalid("不支持的网关版本")
            rid = req.get("id")
            if not isinstance(rid, str) or not 1 <= len(rid) <= 80:
                raise Invalid("请求 ID 无效")
            digest = hashlib.sha256(canonical(req)).hexdigest()
            if rid in self.seen:
                old_digest, old_reply = self.seen[rid]
                if digest != old_digest:
                    raise Invalid("同一请求 ID 携带不同内容")
                return copy.deepcopy(old_reply)
            if type(req.get("time")) not in (int, float) or abs(time.time() - req["time"]) > 30:
                raise Invalid("请求已过期或时钟偏差超过30秒")
            op = req.get("op")
            trace = []
            if op == "apply":
                if req.get("boot_id") != self.boot_id or req.get("revision") != self.revision:
                    raise Invalid("设备状态已改变，请重新读取并生成计划")
                patch = validate_patch(req.get("changes"))
                wire = uart_preview(patch, self.state, self.revision)
                # Simulates the FUTURE semantic adapter and first-board frame commit.
                # UART gaps are intentionally not encoded using invented opcodes.
                self.state.update(patch)
                self.revision += 1
                trace = ["第二板模拟器：校验能力与状态版本", "第二板模拟器：生成 UART 编码预览", "第一板模拟器：语义事务一次性提交", "第一板模拟器：APPLIED + 状态回读"]
            elif op == "status":
                wire = None
            else:
                raise Invalid("未知网关操作")
            reply = {"v": 1, "id": rid, "status": "applied" if op == "apply" else "snapshot",
                     "simulated": True, "boot_id": self.boot_id, "revision": self.revision,
                     "state": copy.deepcopy(self.state), "capabilities": capabilities(lite=True), "uart": wire, "trace": trace}
            self.seen[rid] = (digest, copy.deepcopy(reply))
            while len(self.seen) > 256:
                self.seen.popitem(last=False)
            return reply


class Transport:
    def __init__(self, address=None, secret=""):
        self.gateway = Gateway() if address is None else None
        self.address = address
        self.secret = secret

    def request(self, op, **kwargs):
        req = {"v": 1, "id": uuid.uuid4().hex, "time": time.time(), "op": op, **kwargs}
        if self.gateway:
            return self.gateway.handle(req)
        raw = pack(req, self.secret)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(self.address)
            sock.settimeout(0.6)
            for _ in range(3):
                sock.send(raw)  # Retry the identical id + body, never a fresh action.
                deadline = time.monotonic() + 0.6
                while time.monotonic() < deadline:
                    try:
                        data = sock.recv(8193)
                        reply = unpack(data, self.secret)
                    except socket.timeout:
                        break
                    if not isinstance(reply, dict) or reply.get("id") != req["id"]:
                        continue
                    if reply.get("error"):
                        raise Invalid(reply["error"])
                    if reply.get("v") != 1 or reply.get("simulated") is not True:
                        raise Invalid("此 demo 只允许软件网关，实板适配器尚未实现")
                    if set(reply.get("state", {})) != set(DEFAULT):
                        raise Invalid("网关返回的状态不完整")
                    validate_patch(reply["state"])
                    return reply
        raise Invalid("网关未确认：结果未知。请刷新读取状态后再操作；发送成功不等于第一板生效。")


def serve(host, port, secret, stop=None, ready=None, drop_first=False):
    gateway = Gateway()
    dropped = set()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((host, port))
        sock.settimeout(0.2)
        if ready:
            ready(sock.getsockname())
        while not stop or not stop.is_set():
            try:
                raw, peer = sock.recvfrom(8193)
            except socket.timeout:
                continue
            req = None
            try:
                req = unpack(raw, secret)
                reply = gateway.handle(req)
            except (Invalid, ValueError, TypeError):
                # Invalid MACs get no response. Valid but rejected requests get authenticated errors.
                if isinstance(req, dict):
                    sock.sendto(pack({"id": req.get("id"), "error": "网关拒绝请求：校验失败、能力不支持或状态版本冲突"}, secret), peer)
                continue
            if drop_first and req["op"] == "apply" and req["id"] not in dropped:
                dropped.add(req["id"])
                continue
            sock.sendto(pack(reply, secret), peer)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="第二板/第一板软件 UDP 模拟器，不控制真实硬件")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=19026)
    parser.add_argument("--drop-first", action="store_true", help="模拟每次 apply 的首次 ACK 丢失")
    args = parser.parse_args()
    secret = os.environ.get("AGENT_GATEWAY_SECRET", "")
    if len(secret) < 16:
        parser.error("请设置至少16字符的 AGENT_GATEWAY_SECRET；两个进程使用同一值")
    print(f"Software gateway udp://{args.host}:{args.port} (simulated only)", flush=True)
    try:
        serve(args.host, args.port, secret, drop_first=args.drop_first)
    except KeyboardInterrupt:
        pass
