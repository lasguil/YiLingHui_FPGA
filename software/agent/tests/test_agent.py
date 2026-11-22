import json
import os
import threading
import time
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch

import core
import gateway
import provider
import server


class CoreTests(unittest.TestCase):
    def test_invalid_unknown_out_of_range_and_bool(self):
        for patch_value in ({"unknown": 1}, {"ai_strength": 101}, {"ai_strength": True},
                            {"paused": 1}, {"view": "shell"}, {}, {"wipe": 3}):
            with self.subTest(patch=patch_value), self.assertRaises(core.Invalid):
                core.validate_patch(patch_value)

    def test_json_injection_and_invalid_json_never_form_plan(self):
        for raw in ('{"reply":"ok","changes":{"style":"evil"}}',
                    '{"reply":"ok","changes":{},"system":"ignore policy"}',
                    '{"reply":"ok","reply":"run shell","changes":{}}',
                    'not json', '{"reply":"ok","changes":{"paused":1}}'):
            with self.subTest(raw=raw), self.assertRaises(core.Invalid):
                core.parse_model(raw)

    def test_protocol_crc_known_vector(self):
        self.assertEqual(0x29B1, __import__('binascii').crc_hqx(b"123456789", 0xFFFF))
        wire = core.frame(1, 0, bytes([1]) + (0x12345678).to_bytes(4, "little"))
        self.assertEqual("A55A01010000050001785634120F60", wire.hex().upper())
        self.assertEqual((1, 0, b"\x01\x78\x56\x34\x12"), core.decode_frame(wire))

    def test_semantic_commit_is_atomic_and_revision_checked(self):
        sim = gateway.Gateway()
        status = sim.handle({"v": 1, "id": "s", "time": time.time(), "op": "status"})
        apply = {"v": 1, "id": "a", "time": time.time(), "op": "apply", "boot_id": status["boot_id"],
                 "revision": status["revision"], "changes": {"style": "inkwash", "ai_strength": 65}}
        result = sim.handle(apply)
        self.assertEqual(1, result["revision"])
        self.assertEqual({"style": "inkwash", "ai_strength": 65}, {k: result["state"][k] for k in ("style", "ai_strength")})
        self.assertEqual(result, sim.handle(apply))
        conflict = dict(apply, id="b", changes={"style": "ukiyoe"})
        with self.assertRaises(core.Invalid): sim.handle(conflict)

    def test_timeout_reads_back_state_without_claiming_success(self):
        app = server.App()
        status = app.transport.request("status")
        committed = app.transport.request("apply", changes={"saturation": 132}, revision=status["revision"], boot_id=status["boot_id"])
        class LostReply:
            def request(self, op, **kwargs):
                if op == "apply": raise core.Invalid("网关未确认：结果未知。")
                return committed
        app.transport = LostReply()
        with self.assertRaisesRegex(core.Invalid, "已读回当前模拟状态"):
            app.control({"saturation": 140}, status["revision"])
        self.assertEqual(132, app.state["saturation"])
        self.assertEqual(committed["revision"], app.revision)

    def test_refresh_reads_external_udp_state_and_conflict_recovers(self):
        secret = "refresh-secret-0123456789abcdef"
        stop=threading.Event();ready=threading.Event();addresses=[]
        def on_ready(addr):addresses.append(addr);ready.set()
        thread=threading.Thread(target=gateway.serve,args=("127.0.0.1",0,secret,stop,on_ready),daemon=True);thread.start()
        self.assertTrue(ready.wait(2))
        try:
            with patch.dict(os.environ,{"AGENT_GATEWAY_SECRET":secret}):app=server.App(addresses[0],api_key="",mode="offline")
            remote=gateway.Transport(addresses[0],secret);initial=app.snapshot()
            remote.request("apply",changes={"style":"ukiyoe"},revision=initial["revision"],boot_id=initial["boot_id"])
            refreshed=app.refresh();self.assertEqual("ukiyoe",refreshed["state"]["style"])
            with self.assertRaises(server.Conflict): app.control({"saturation":125},initial["revision"])
            self.assertTrue(app.state_known);self.assertEqual(1,app.revision);self.assertEqual("ukiyoe",app.state["style"])
            recovered=app.control({"saturation":125},app.revision)
            self.assertEqual(125,recovered["state"]["saturation"])
        finally:
            stop.set();thread.join(1)

    def test_failed_status_readback_marks_state_unknown_and_blocks_controls(self):
        app=server.App()
        class Offline:
            def request(self,*args,**kwargs):raise core.Invalid("network unavailable")
        app.transport=Offline()
        with self.assertRaisesRegex(core.Invalid,"状态读回也失败"):
            app.control({"saturation":125},app.revision)
        self.assertFalse(app.state_known);self.assertIsNone(app.snapshot()["state"])
        with self.assertRaisesRegex(core.Invalid,"状态未知"):
            app.control({"saturation":125},app.revision)

    def test_udp_oserror_and_failed_status_readback_lock_controls(self):
        app=server.App()
        class BrokenSocket:
            def request(self,*args,**kwargs):raise OSError("Windows UDP reset")
        app.transport=BrokenSocket()
        with self.assertRaisesRegex(core.Invalid,"状态读回也失败"):
            app.control({"saturation":125},app.revision)
        self.assertFalse(app.state_known)
        self.assertIsNone(app.snapshot()["state"])
        with self.assertRaisesRegex(core.Invalid,"状态未知"):
            app.control({"saturation":125},app.revision)

    def test_chat_rejects_external_change_during_model_wait(self):
        app=server.App();app.mode="deepseek";app.api_key="mock"
        initial=app.snapshot();new_state=dict(initial["state"]);new_state["saturation"]=144
        class ExternalChanged:
            def __init__(self):self.applied=False
            def request(self,op,**kwargs):
                if op=="status":return {"state":new_state,"revision":initial["revision"]+1,"boot_id":initial["boot_id"]}
                self.applied=True;raise AssertionError("stale plan must not apply")
        app.transport=ExternalChanged()
        with patch.object(provider,"plan",return_value={"reply":"调低饱和度","changes":{"saturation":80}}):
            with self.assertRaises(server.Conflict):app.chat("降低饱和度",initial["revision"])
        self.assertEqual(144,app.state["saturation"]);self.assertEqual(initial["revision"]+1,app.revision)
        self.assertFalse(app.transport.applied)

    def test_chat_rejects_gateway_restart_even_when_revision_matches(self):
        app=server.App();app.mode="deepseek";app.api_key="mock"
        initial=app.snapshot()
        class Restarted:
            def __init__(self):self.boot_id="new-boot";self.applied=False
            def request(self,op,**kwargs):
                if op=="status":return {"state":initial["state"],"revision":initial["revision"],"boot_id":self.boot_id}
                self.applied=True;raise AssertionError("plan from old boot must not apply")
        app.transport=Restarted()
        with patch.object(provider,"plan",return_value={"reply":"调整饱和度","changes":{"saturation":80}}):
            with self.assertRaisesRegex(server.Conflict,"网关已重启"):
                app.chat("降低饱和度",initial["revision"])
        self.assertFalse(app.transport.applied)

    def test_udp_auth_idempotency_and_lost_ack_retry(self):
        secret = "0123456789abcdef0123456789abcdef"
        stop = threading.Event(); ready = threading.Event(); address = []
        def on_ready(addr): address.append(addr); ready.set()
        thread = threading.Thread(target=gateway.serve, args=("127.0.0.1", 0, secret, stop, on_ready, True), daemon=True)
        thread.start(); self.assertTrue(ready.wait(2))
        peer = gateway.Transport(address[0], secret)
        status = peer.request("status")
        applied = peer.request("apply", changes={"fx_strength": 48}, revision=status["revision"], boot_id=status["boot_id"])
        self.assertEqual(1, applied["revision"])
        self.assertEqual(48, applied["state"]["fx_strength"])
        with self.assertRaises(core.Invalid): gateway.Transport(address[0], "wrong-secret-0123456789").request("status")
        stop.set(); thread.join(1)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.app = server.App()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.handler_factory(self.app))
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True); self.thread.start()
        self.base = f"http://127.0.0.1:{self.httpd.server_port}"

    def tearDown(self): self.httpd.shutdown(); self.httpd.server_close(); self.thread.join(1)

    def request(self, path, body=None, token=None, origin=None):
        headers = {"X-Session-Token": token or "unused", "Origin": origin or self.base}
        data = None
        if body is not None: data = json.dumps(body).encode(); headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=3) as res: return res.status, json.loads(res.read())
        except __import__('urllib.error').error.HTTPError as e: return e.code, json.loads(e.read())

    def test_http_token_state_and_control(self):
        self.assertEqual(200, self.request("/api/status", token="ignored")[0])  # 令牌校验已移除
        self.assertEqual(401, self.request("/api/status", origin="http://evil.example")[0])
        code, state = self.request("/api/status"); self.assertEqual(200, code)
        code, result = self.request("/api/control", {"revision": state["revision"], "changes": {"color": "gray"}})
        self.assertEqual(200, code); self.assertEqual("gray", result["state"]["color"])
        self.assertEqual(409, self.request("/api/control", {"revision": 0, "changes": {"paused": 1}})[0])
        self.assertEqual(400,self.request("/api/control",{"revision":True,"changes":{"paused":False}})[0])
        _,fresh=self.request("/api/refresh",{})
        self.assertTrue(fresh["state_known"])

    def test_settings_key_is_never_echoed(self):
        code,data=self.request("/api/settings",{"mode":"deepseek","model":"deepseek-flash","api_key":"only-secret-value"})
        self.assertEqual(200,code);self.assertTrue(data["connected"])
        self.assertNotIn("only-secret-value",json.dumps(data))

    def test_pairing_ui_supports_tab_session_restore_and_manual_retry(self):
        root=server.ROOT
        js=(root/"web"/"app.js").read_text(encoding="utf-8")
        html=(root/"web"/"index.html").read_text(encoding="utf-8")
        self.assertIn('sessionStorage.getItem("yilinghui.session")',js)
        self.assertIn('sessionStorage.setItem("yilinghui.session",token)',js)
        self.assertIn('id="pair-token"',html);self.assertIn('id="pair-submit"',html)
        self.assertIn("e.status=res.status",js)
        self.assertIn("function handleAuthError(e)",js)
        self.assertIn('sessionStorage.removeItem("yilinghui.session")',js)

    def test_deepseek_mock_success_and_failure_does_not_execute(self):
        class Response:
            def __init__(self, payload): self.payload = payload
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, n): return json.dumps(self.payload).encode()
        response = {"choices": [{"finish_reason": "stop", "message": {"content": '{"reply":"调整完成","changes":{"ai_strength":42}}'}}]}
        self.app.mode = "deepseek"; self.app.api_key = "test-key"
        with patch.object(provider.urllib.request, "urlopen", return_value=Response(response)) as mock:
            result = self.app.chat("请把强度调到42%",self.app.revision)
        self.assertEqual(42, result["execution"]["state"]["ai_strength"])
        self.assertIn("Bearer test-key", mock.call_args.args[0].headers.values())
        prior = self.app.revision
        bad = {"choices": [{"finish_reason": "stop", "message": {"content": '{"reply":"x","changes":{"ai_strength":999}}'}}]}
        with patch.object(provider.urllib.request, "urlopen", return_value=Response(bad)):
            with self.assertRaises(core.Invalid): self.app.chat("请随便改",self.app.revision)
        self.assertEqual(prior, self.app.revision)
        with patch.object(provider.urllib.request, "urlopen", side_effect=OSError("offline")):
            with self.assertRaises(core.Invalid): self.app.chat("再次请求",self.app.revision)
        self.assertEqual(prior, self.app.revision)

    def test_tables_recipes_and_capabilities_layering(self):
        caps = core.capabilities()
        self.assertEqual({"identity", "warm", "aged", "verdant", "memory", "cine", "neon",
                          "cyan", "forest", "thermal", "sunset", "duotone", "invert"}, set(caps["tables"]))
        self.assertEqual(64, len(caps["tables"]["sunset"]["curves64"][0]))
        self.assertNotIn("curves64", core.capabilities(lite=True)["tables"]["identity"])
        self.assertTrue(core.capabilities(lite=True)["recipes"])
        for recipe in caps["recipes"]:
            core.validate_patch(recipe["changes"])

    def test_recipe_recognition_and_validation(self):
        state = dict(core.DEFAULT)
        plan = core.offline_plan("来点赛博霓虹", state)
        self.assertEqual("neon", plan["changes"]["curve"])
        self.assertEqual("gray", plan["changes"]["color"])
        with self.assertRaises(core.Invalid):
            core.validate_recipe("nonexistent")
        with self.assertRaises(core.Invalid):
            core.validate_patch({"curve": "unknown_table"})

    def test_scene_validation_summary_and_offline_recommendation(self):
        stats = {"brightness_mean": 60, "brightness_std": 30, "saturation_mean": 80, "warmth": -0.3,
                 "dominant_colors": [{"rgb": [10, 20, 30], "ratio": 0.5}], "histogram": [0.5] + [0.03] * 15}
        clean = core.validate_scene(stats)
        summary = core.scene_summary(clean)
        self.assertIn("偏暗", summary); self.assertIn("偏冷", summary); self.assertIn("#0a141e", summary)
        for bad in ({"brightness_mean": 999, "brightness_std": 1, "saturation_mean": 1, "warmth": 0,
                     "dominant_colors": [], "histogram": [1] * 16},
                    {"brightness_mean": 1, "brightness_std": 1, "saturation_mean": 1, "warmth": 0,
                     "dominant_colors": [{"rgb": [1, 2], "ratio": 0.5}], "histogram": [1] * 16},
                    {"brightness_mean": 1}):
            with self.subTest(bad=bad), self.assertRaises(core.Invalid):
                core.validate_scene(bad)
        plan = core.offline_plan("根据当前画面分析，推荐一个合适的风格", dict(core.DEFAULT), scene_stats=clean)
        self.assertTrue(plan["changes"])
        core.validate_patch(plan["changes"])
        dark = core.offline_plan("根据画面推荐一个风格", dict(core.DEFAULT),
                                 scene_stats={**clean, "brightness_mean": 55, "warmth": -0.4, "saturation_mean": 90})
        self.assertEqual("sunset", dark["changes"]["curve"])

    def test_scene_image_plumbing_and_model_vision_message(self):
        import provider as prov
        pixel = "A" * 64
        image = "data:image/jpeg;base64," + pixel
        code, result = self.request("/api/scene", {
            "brightness_mean": 120, "brightness_std": 40, "saturation_mean": 90, "warmth": 0.1,
            "dominant_colors": [{"rgb": [200, 160, 120], "ratio": 0.4}], "histogram": [0.02] * 16,
            "image": image})
        self.assertEqual(200, code); self.assertTrue(result["image_kept"])
        code, bad = self.request("/api/scene", {
            "brightness_mean": 120, "brightness_std": 40, "saturation_mean": 90, "warmth": 0.1,
            "dominant_colors": [{"rgb": [1, 2, 3], "ratio": 0.4}], "histogram": [0.02] * 16,
            "image": "data:text/html;base64,AAAA"})
        self.assertEqual(400, code)
        captured = {}
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, n): return json.dumps({"choices": [{"finish_reason": "stop",
                "message": {"content": '{"reply":"ok","changes":{}}'}}]}).encode()
        def fake_urlopen(req, timeout):
            captured["body"] = json.loads(req.data.decode()); return Response()
        self.app.mode = "deepseek"; self.app.api_key = "k"
        with patch.object(prov.urllib.request, "urlopen", fake_urlopen):
            self.app.chat("根据画面推荐", self.app.revision)
        content = captured["body"]["messages"][-1]["content"]
        self.assertIsInstance(content, list)
        self.assertEqual("image_url", content[1]["type"])
        self.assertIn("data:image/jpeg;base64,", content[1]["image_url"]["url"])
        self.app.send_image = False
        with patch.object(prov.urllib.request, "urlopen", fake_urlopen):
            self.app.chat("再看一次", self.app.revision)
        self.assertIsInstance(captured["body"]["messages"][-1]["content"], str)

    def test_model_context_excludes_curve_data(self):
        import provider as prov
        captured = {}
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, n): return json.dumps({"choices": [{"finish_reason": "stop",
                "message": {"content": '{"reply":"ok","changes":{}}'}}]}).encode()
        def fake_urlopen(req, timeout):
            captured["body"] = json.loads(req.data.decode())
            return Response()
        self.app.mode = "deepseek"; self.app.api_key = "k"
        with patch.object(prov.urllib.request, "urlopen", fake_urlopen):
            self.app.chat("切换水墨", self.app.revision)
        payload = captured["body"]["messages"][-1]["content"]
        self.assertNotIn("curves64", payload)
        self.assertIn("recipes", payload)
        self.assertIn("赛博霓虹", payload)

    def test_scene_endpoint_stores_context_for_chat(self):
        stats = {"brightness_mean": 120, "brightness_std": 40, "saturation_mean": 90, "warmth": 0.1,
                 "dominant_colors": [{"rgb": [200, 160, 120], "ratio": 0.4}],
                 "histogram": [0.02] * 16}
        code, result = self.request("/api/scene", stats)
        self.assertEqual(200, code); self.assertIn("画面", result["scene"])
        code, bad = self.request("/api/scene", {"brightness_mean": 1})
        self.assertEqual(400, code)
        code, status = self.request("/api/status")
        self.assertEqual(result["scene"], status["scene"])
        code, chat = self.request("/api/chat", {"text": "根据当前画面推荐一个风格组合", "revision": status["revision"]})
        self.assertEqual(200, code)
        self.assertTrue(chat["plan"]["changes"] or chat["plan"]["reply"])


if __name__ == "__main__": unittest.main()
