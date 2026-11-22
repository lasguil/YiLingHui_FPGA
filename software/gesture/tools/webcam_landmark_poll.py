r"""摄像头 demo：hand_landmark_lite 轮询搜索 + 锁定跟踪（总推理次数受控）。

为什么是"轮询 + 收敛"而不是"一次检测"：
  hand_landmark_lite 只会**精修**，不会**搜索**（它不是检测器）。在 720p 静态图上实测：
    * 它对裁剪框的容忍半径 ≈ **0.15 × 窗口边长**（窗口 632px 时 80px，窗口 486px 时 60px）；
    * 种子落进容忍圈后，用"上一帧自己的关键点"迭代裁剪 **2~12 帧**即收敛到 conf>0.9；
      锁定后 conf 稳定 0.93~0.98；平移序列每帧 Δy 与真值差 <15%（常量偏差约 6px，判位移时会被差分消掉）；
    * 落在容忍圈外时 conf 掉到 0.00~0.01，**没有任何梯度可爬**，只能换窗口重试。
  所以搜索只能靠"多尺度 + 从左到右从上到下顺序扫，命中即收敛"，成本就是窗口数。

算力口径（唯一的硬约束：模型每秒算多少张图）：
  全流程只有 hand_landmark_lite 一个模型（224×224，145.6 MMAC/次）。
  **一张 = 一次 224×224 前向**，跟踪裁剪和轮询窗口单价相同。
  全局限流 --inf-per-sec（默认 15），同一帧不会重复算：
    搜索：按从左到右、从上到下的顺序扫，最坏 = 窗口数 / 15 秒（720p 默认 31 个 → 2.1 秒）
    收敛：命中后 2~12 张（0.13~0.8 秒）
    跟踪：锁定后每个新帧算一张，即 15 张/秒
  界面第二行的 "infer x/s (cap 15)" 就是实时用量。
  15 张/秒 = 145.6 × 15 = 2.18 GMAC/s（16 DSP 保守口径 1.6 的 1.37 倍、乐观 4.55 的 48%）。

按键：q/ESC 退出，s 存图，r 重新扫描。
关于裁剪旋转：**默认只平移**（裁剪框 = 掌点轴对齐包围盒 → 上移 0.4×高 → 放大 3 倍）。
摄像机实测这样够用，而且省掉了每帧的任意角度重采样（板上只需缩放拷贝，和 v4 的中央方框同一套硬件）。
加 --crop-rotate 才按 MediaPipe 约定把"手腕→中指根"转成朝上再喂。
注意边界：手明显倾斜时（实测 720p 截图里手腕→中指根偏竖直约 25°）只平移会让置信度从 0.94 掉到 0.04、收不敛，
那时要用 --crop-rotate；手基本竖直（<10°）时两者都行。

用法（PowerShell / cmd；先清掉 Efinity 遗留的 Python 环境变量）：
    set PYTHONHOME=
    set PYTHONPATH=
    C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe gesture\tools\webcam_landmark_poll.py --camera 0
  离线自测（不开窗口、用图片跑）：
    ... gesture\tools\webcam_landmark_poll.py --source webcam_demo_still.png --headless --frames 120

调参建议（对着摄像头现场调）：
    * 手离镜头 0.5~1m、在画面里约 500px 高、放在**画面中央**——中心向外扫描会先扫中间；
    * 锁不住 → 加尺度（--coarse 0.9 0.7 0.5）或降 --t-poll 到 0.01，同时看 [poll] 行报的最高分；
    * 锁住后容易掉 → 降 --t-lost（0.4）或加 --lost-frames（5）；
    * 想省算力 → 减 --max-windows（代价是搜索变慢或容易漏）。

依赖：ai-edge-litert、opencv-python、numpy。模型：models/reference/hand_landmark_lite.tflite。
"""

import argparse
import os
import sys
import threading
import time

import cv2 as cv
import numpy as np

# ------------------------------------------------------------------ 关键点与骨架
PALM_LANDMARK_IDS = [0, 5, 9, 13, 17, 1, 2]   # 手腕 + 四指根 + 拇指两点
IDX_PALM_BASE, IDX_MIDDLE_BASE = 0, 2         # 在 PALM_LANDMARK_IDS 里的下标
PALM_BOX_SHIFT = np.array([0.0, -0.4])
PALM_BOX_ENLARGE = 3.0
HAND_BOX_SHIFT = np.array([0.0, -0.1])
HAND_BOX_ENLARGE = 1.65
HAND_CONNECTIONS = [
    (0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8),
    (5, 9), (9, 10), (10, 11), (11, 12), (9, 13), (13, 14), (14, 15), (15, 16),
    (13, 17), (17, 18), (18, 19), (19, 20), (0, 17),
]

DEFAULT_MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             '..', 'models', 'reference', 'hand_landmark_lite.tflite')


class LiteLandmark:
    """hand_landmark_lite 的裁剪几何 + 推理 + 坐标映射（只用这一个模型）。"""

    def __init__(self, model_path, input_size=224):
        self.last_ms = 0.0
        self.rotate = True          # False = 跟踪裁剪只平移不旋转
        self.onnx = str(model_path).lower().endswith('.onnx')
        if self.onnx:                     # ONNX（含量化版）走 onnxruntime，数值约定与 tflite 一致
            import onnxruntime as ort
            self.sess = ort.InferenceSession(str(model_path), providers=['CPUExecutionProvider'])
            self.in_name = self.sess.get_inputs()[0].name
            self.input_size = float(input_size)
            return
        from ai_edge_litert.interpreter import Interpreter
        self.it = Interpreter(model_path=model_path)
        self.it.allocate_tensors()
        self.inp = self.it.get_input_details()[0]
        self.outs = self.it.get_output_details()
        self.input_size = float(input_size)

    # ---- 推理 ----
    def _run(self, tile_bgr):
        t0 = time.perf_counter()
        tile = cv.resize(tile_bgr, (int(self.input_size), int(self.input_size)), interpolation=cv.INTER_AREA)
        blob = cv.cvtColor(tile, cv.COLOR_BGR2RGB).astype(np.float32) / 255.0
        if self.onnx:
            out = self.sess.run(None, {self.in_name: blob[np.newaxis]})
            raw = np.asarray(out[0]).reshape(-1, 3)[:, :2].astype(np.float64)
            conf = float(np.ravel(out[1])[0])
            handed = float(np.ravel(out[2])[0])
            self.last_ms = (time.perf_counter() - t0) * 1e3
            return raw, conf, handed
        self.it.set_tensor(self.inp['index'], blob[np.newaxis].astype(self.inp['dtype']))
        self.it.invoke()
        raw = self.it.get_tensor(self.outs[0]['index']).reshape(-1, 3)[:, :2].astype(np.float64)
        conf = float(np.ravel(self.it.get_tensor(self.outs[1]['index']))[0])
        handed = float(np.ravel(self.it.get_tensor(self.outs[2]['index']))[0])
        self.last_ms = (time.perf_counter() - t0) * 1e3
        return raw, conf, handed

    def infer_window(self, image, box):
        """轮询：把方形窗口直接当裁剪，不旋转、无先验。box=(x1,y1,x2,y2)。"""
        x1, y1, x2, y2 = box
        cx, cy = (x1 + x2) / 2.0, (y1 + y2) / 2.0
        side = max(x2 - x1, y2 - y1)
        x0, y0 = cx - side / 2.0, cy - side / 2.0
        h, w = image.shape[:2]
        pl, pt = max(0.0, -x0), max(0.0, -y0)
        pr, pb = max(0.0, x0 + side - w), max(0.0, y0 + side - h)
        crop = image[max(0, int(y0)):int(y0 + side - pb), max(0, int(x0)):int(x0 + side - pr)]
        if crop.size == 0:
            return None
        if pl or pt or pr or pb:
            crop = cv.copyMakeBorder(crop, int(pt), int(pb), int(pl), int(pr), cv.BORDER_REPLICATE)
        raw, conf, handed = self._run(crop)
        pts = raw * side / self.input_size + np.array([x0, y0])   # 左上原点像素约定
        return pts, conf, handed, (x0, y0, x0 + side, y0 + side)

    @staticmethod
    def palm_from_landmarks(pts):
        palm = np.asarray(pts)[PALM_LANDMARK_IDS]
        return palm, np.array([palm.min(axis=0), palm.max(axis=0)])

    def infer_tracked(self, image, palm_pts, palm_box):
        """跟踪：裁剪框来自上一帧自己的关键点，按"手腕→中指根"旋转对齐。"""
        img, box, bias = self._crop_pad(image, np.asarray(palm_box, float).reshape(2, 2), 4.0,
                                        np.array([0.0, 0.0]), black_pad=True)
        if img.size == 0:
            return None
        rgb = cv.cvtColor(img, cv.COLOR_BGR2RGB)
        box = box - bias
        pts = np.asarray(palm_pts, float) - bias
        p1, p2 = pts[IDX_PALM_BASE], pts[IDX_MIDDLE_BASE]
        if self.rotate:
            rad = np.pi / 2 - np.arctan2(-(p2[1] - p1[1]), p2[0] - p1[0])
            rad = rad - 2 * np.pi * np.floor((rad + np.pi) / (2 * np.pi))
            angle = np.rad2deg(rad)
        else:
            angle = 0.0
        center = box.sum(axis=0) / 2
        if angle != 0.0:
            rot = cv.getRotationMatrix2D(tuple(center), angle, 1.0)
            rotated = cv.warpAffine(rgb, rot, (rgb.shape[1], rgb.shape[0]))
        else:
            rot = np.array([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
            rotated = rgb
        hom = np.c_[pts, np.ones(len(pts))]
        rpts = np.array([hom @ rot[0], hom @ rot[1]])
        rbox = np.array([rpts.min(axis=1), rpts.max(axis=1)])
        crop, rbox, _ = self._crop_pad(rotated, rbox, PALM_BOX_ENLARGE, PALM_BOX_SHIFT)
        if crop.size == 0:
            return None
        raw, conf, handed = self._run(crop)
        pts, bbox = self._map_back(raw, rbox, angle, rot, bias)
        return pts, conf, handed, bbox

    @staticmethod
    def _crop_pad(image, box, enlarge, shift, black_pad=False):
        wh = box[1] - box[0]
        box = box + shift * wh
        center = box.sum(axis=0) / 2
        half = wh * enlarge / 2
        b = np.array([center - half, center + half]).astype(np.int32)
        b[:, 0] = np.clip(b[:, 0], 0, image.shape[1])
        b[:, 1] = np.clip(b[:, 1], 0, image.shape[0])
        crop = image[b[0][1]:b[1][1], b[0][0]:b[1][0], :]
        if crop.size == 0:
            return crop, b, b[0]
        side = max(crop.shape[:2])
        ph, pw = side - crop.shape[0], side - crop.shape[1]
        lt, tp = pw // 2, ph // 2
        border = cv.BORDER_CONSTANT if black_pad else cv.BORDER_REPLICATE
        crop = cv.copyMakeBorder(crop, tp, ph - tp, lt, pw - lt, border, None,
                                 (0, 0, 0) if black_pad else None)
        return crop, b, b[0] - [lt, tp]

    def _map_back(self, raw, rbox, angle, rot, pad_bias):
        wh = rbox[1] - rbox[0]
        pts = (raw - self.input_size / 2) * max(wh / self.input_size)
        cm = cv.getRotationMatrix2D((0, 0), angle, 1.0)
        rp = pts @ cm[:, :2]
        rc = np.array([[rot[0][0], rot[1][0]], [rot[0][1], rot[1][1]]])
        tc = np.array([rot[0][2], rot[1][2]])
        inv = np.c_[rc, np.array([-rc[0] @ tc, -rc[1] @ tc])]
        center = np.append(rbox.sum(axis=0) / 2, 1)
        pts = rp + np.array([center @ inv[0], center @ inv[1]]) + pad_bias
        bbox = np.array([pts.min(axis=0), pts.max(axis=0)])
        wh = bbox[1] - bbox[0]
        bbox = bbox + HAND_BOX_SHIFT * wh
        c = bbox.sum(axis=0) / 2
        half = (bbox[1] - bbox[0]) * HAND_BOX_ENLARGE / 2
        return pts, np.array([c - half, c + half])



class InferWorker(threading.Thread):
    """独占模型与状态机，限速消费"最新一帧"；主线程只负责显示，互不阻塞。

    限速语义：两次推理的最小间隔 = 1 / inf_per_sec（令牌桶式，无突发）。
    没有新帧时线程睡眠，不会空转吃 CPU。
    """

    def __init__(self, tracker, args):
        super().__init__(daemon=True)
        self.tr = tracker
        self.args = args
        self.min_interval = 1.0 / max(args.inf_per_sec, 1)
        self._lock = threading.Lock()
        self._frame = None
        self._fid = 0
        self._seen = -1
        self._stop = False

    def submit(self, frame, fid):
        with self._lock:
            self._frame = frame
            self._fid = fid

    def stop(self):
        self._stop = True

    def run(self):
        while not self._stop:
            with self._lock:
                frame, fid = self._frame, self._fid
            if frame is None or fid == self._seen:
                time.sleep(0.0015)
                continue
            t0 = time.perf_counter()
            self._seen = fid
            self.tr.step(frame)
            self.tr.note_result()
            rest = self.min_interval - (time.perf_counter() - t0)
            if rest > 0:
                time.sleep(rest)


class PollTracker:
    """轮询 → 收敛 → 跟踪 的状态机；同时管住每秒推理次数。

    实测约束（本项目在 720p 静态图上标定）：
      * landmark 模型对裁剪框的"容忍半径" ≈ 0.15 × 窗口边长（窗口 632px 时只有 80px）；
      * 因此轮询窗口必须**多尺度 + 中心向外**排序，否则很难一次命中；
      * 命中后 ACQUIRE 迭代 2~12 帧即收敛到 conf>0.9，比盲扫便宜得多。
    每帧最多 1 次推理，所以扫描 N 个窗口最坏要 N/`--inf-per-sec` 秒。
    """

    def __init__(self, model, w, h, args):
        self.m = model
        self.w, self.h = w, h
        self.args = args
        self.state = 'POLL'
        self.pts = self.bbox = None
        self.seed_pts = None
        self.conf = self.handed = 0.0
        self.lost_count = self.acq_count = 0
        self.stamps = []
        self.total_inf = self.locks = 0
        self.last_win = None
        self.last_result_time = 0.0
        self.ok = False
        self._build_sweep()

    # ---- 轮询计划：多尺度 + 中心向外 ----
    def _build_sweep(self):
        boxes = []
        for scale in self.args.coarse:
            side = scale * self.h
            step = max(16.0, side * self.args.stride)
            ny = max(1, int(np.ceil((self.h - side) / step)) + 1)
            nx = max(1, int(np.ceil((self.w - side) / step)) + 1)
            off_y = (self.h - (ny - 1) * step - side) / 2
            off_x = (self.w - (nx - 1) * step - side) / 2
            for j in range(ny):
                for i in range(nx):
                    x = off_x + i * step
                    y = off_y + j * step
                    boxes.append((x, y, x + side, y + side))
        # 顺序：尺度按命令行顺序，每个尺度内**从左到右、从上到下**（j 行外层，i 列内层）
        if self.args.max_windows and len(boxes) > self.args.max_windows:
            boxes = boxes[:self.args.max_windows]
        self.queue = boxes
        self.win_total = len(boxes)
        self.win_index = 0
        self.state = 'POLL'
        self.acq_count = 0
        print(f'[poll] 新一轮扫描：{len(boxes)} 个窗口（尺度 {self.args.coarse}，从左到右从上到下），'
              f'最坏 {len(boxes) / max(self.args.inf_per_sec, 1):.1f} 秒', flush=True)

    def step(self, frame):
        """调用一次 = 做一次推理（限速由 InferWorker 负责）。"""
        now = time.time()
        if self.state == 'POLL':
            if self.queue:
                box = self.queue.pop(0)
                self.last_win = box
                self.win_index += 1
                r = self.m.infer_window(frame, box)
                self.stamps.append(now)
                self.total_inf += 1
                if r is not None and r[1] >= self.args.t_poll:
                    # 扫到第一个"像手"的窗口就直接去收敛，不再扫完整轮
                    self.seed_pts, self.conf = r[0], r[1]
                    self.state = 'ACQUIRE'
                    self.acq_count = 0
                    print(f'[poll] 第 {self.win_index}/{self.win_total} 个窗口命中 conf={r[1]:.3f}，开始收敛',
                          flush=True)
                return True
            print('[poll] 整轮扫完没有命中，重扫', flush=True)
            self._build_sweep()
            return False

        if self.state == 'ACQUIRE':
            palm_pts, palm_box = self.m.palm_from_landmarks(self.seed_pts)
            r = self.m.infer_tracked(frame, palm_pts, palm_box)
            self.stamps.append(now)
            self.total_inf += 1
            self.acq_count += 1
            if r is not None:
                self.pts, self.conf, self.handed, self.bbox = r
                self.seed_pts = r[0]
                if self.conf >= self.args.t_lock:
                    self.state = 'TRACK'
                    self.locks += 1
                    self.lost_count = 0
                    print(f'[lock] 第 {self.locks} 次锁定 conf={self.conf:.3f}'
                          f'（收敛用 {self.acq_count} 帧，累计推理 {self.total_inf}）', flush=True)
                    return True
            if self.acq_count >= self.args.acquire_max:
                print(f'[acquire] {self.acq_count} 张未收敛到 conf>={self.args.t_lock}，继续往下扫', flush=True)
                self.state = 'POLL'
                if not self.queue:                   # 本轮窗口已扫完
                    self._build_sweep()
            return True

        # TRACK
        palm_pts, palm_box = self.m.palm_from_landmarks(self.pts)
        r = self.m.infer_tracked(frame, palm_pts, palm_box)
        self.stamps.append(now)
        self.total_inf += 1
        if r is not None:
            self.pts, self.conf, self.handed, self.bbox = r
            if self.conf < self.args.t_lost:
                self.lost_count += 1
                if self.lost_count >= self.args.lost_frames:
                    print(f'[lost] 连续 {self.lost_count} 帧 conf<{self.args.t_lost}，重新扫描', flush=True)
                    self._build_sweep()
            else:
                self.lost_count = 0
        return True

    def note_result(self):
        self.last_result_time = time.time()

    def inf_rate(self, now):
        return len([t for t in self.stamps if now - t < 1.0])


# ------------------------------------------------------------------ 绘制


FINGERS = {'index': (5, 6, 7, 8), 'middle': (9, 10, 11, 12),
           'ring': (13, 14, 15, 16), 'pinky': (17, 18, 19, 20)}
FINGER_TIPS = (8, 12, 16, 20)


def palm_metrics(pts, thr_straight=1.20, thr_spread=12.0, thr_thumb=0.90):
    """只用 21 个点判"五指张开的手掌"，全部是尺度无关的比值。

      straight: 四指里最弯那根的"三节骨长和 / 首末直线距离"（伸直≈1，越弯越大）
      spread  : 相邻手指指向的平均夹角（度）——并拢时几度，张开时十几到几十度
      thumb   : 拇指尖到食指根距离 / 掌宽（拇指收到掌心里时小）
    返回 (metrics, 三档判定)。注意：几何分不出掌心/手背，那是外观问题。
    """
    p = np.asarray(pts, dtype=np.float64)
    W, m9, m5, m17 = p[0], p[9], p[5], p[17]
    palm_wid = np.linalg.norm(m5 - m17) + 1e-9
    straight = 0.0
    dirs = {}
    for name, (a, b, c, d) in FINGERS.items():
        chain = (np.linalg.norm(p[b] - p[a]) + np.linalg.norm(p[c] - p[b]) + np.linalg.norm(p[d] - p[c]))
        straight = max(straight, chain / (np.linalg.norm(p[d] - p[a]) + 1e-9))
        dirs[name] = (p[d] - p[a]) / (np.linalg.norm(p[d] - p[a]) + 1e-9)
    names = list(FINGERS)
    angs = []
    for i in range(3):
        c = float(np.dot(dirs[names[i]], dirs[names[i + 1]]))
        angs.append(np.degrees(np.arccos(np.clip(c, -1.0, 1.0))))
    spread = float(np.mean(angs))
    thumb = float(np.linalg.norm(p[4] - p[5]) / palm_wid)
    r1 = straight < thr_straight                      # 五指伸直
    r2 = r1 and spread > thr_spread                   # 且手指分开
    r3 = r2 and thumb > thr_thumb                     # 且拇指张开
    return ({'straight': straight, 'spread': spread, 'thumb': thumb}, (r1, r2, r3))


def ok_metrics(pts, thr_pinch=0.45, thr_straight=1.30, thr_span=0.25):
    """只用 21 个点判 OK 手势（拇指尖和食指尖捏成环，其余三指伸直）。

      pinch : 拇指尖(4)到食指尖(8)距离 / 掌宽 —— OK 时接近 0，张开手掌时 >0.8
      span  : 食指根(5)到食指尖(8)距离 / 掌宽 —— 排除握拳（指节缩在掌心）
      worst : 中/无名/小指里最弯那根的"三节骨长和 / 首末直线距离" —— 排除握拳和半握
    全部尺度无关；食指本身在 OK 里是弯的，所以直度只统计后三指。
    """
    p = np.asarray(pts, dtype=np.float64)
    palm_wid = float(np.linalg.norm(p[5] - p[17])) + 1e-9
    pinch = float(np.linalg.norm(p[4] - p[8]) / palm_wid)
    span = float(np.linalg.norm(p[5] - p[8]) / palm_wid)
    worst = 0.0
    for name in ('middle', 'ring', 'pinky'):
        a, b, c, d = FINGERS[name]
        chain = (np.linalg.norm(p[b] - p[a]) + np.linalg.norm(p[c] - p[b])
                 + np.linalg.norm(p[d] - p[c]))
        worst = max(worst, chain / (np.linalg.norm(p[d] - p[a]) + 1e-9))
    ok = pinch < thr_pinch and worst < thr_straight and span > thr_span
    return ({'pinch': pinch, 'span': span, 'worst': worst}, bool(ok))


def fit_letterbox(img, W, H):
    """把 img 等比缩放进 W×H 画布，多余处补黑边（不变形）。"""
    ih, iw = img.shape[:2]
    if iw == W and ih == H:
        return img
    scale = min(W / iw, H / ih)
    dw, dh = max(1, int(round(iw * scale))), max(1, int(round(ih * scale)))
    resized = cv.resize(img, (dw, dh), interpolation=cv.INTER_AREA if scale < 1 else cv.INTER_LINEAR)
    canvas = np.zeros((H, W, 3), dtype=img.dtype)
    y0, x0 = (H - dh) // 2, (W - dw) // 2
    canvas[y0:y0 + dh, x0:x0 + dw] = resized
    return canvas


def window_rect(name, fallback):
    """读窗口客户区尺寸；拿不到就用 fallback。"""
    try:
        r = cv.getWindowImageRect(name)
        if r and len(r) == 4 and r[2] > 0 and r[3] > 0:
            return r[2], r[3]
    except Exception:
        pass
    return fallback


def draw(frame, tracker, args, fps, inf_rate, show_debug):
    vis = frame.copy()
    h, w = vis.shape[:2]
    st = tracker.state
    color = {'POLL': (0, 200, 255), 'ACQUIRE': (255, 128, 0), 'TRACK': (0, 255, 0)}[st]
    if show_debug:
        for b in tracker.queue[:6]:
            cv.rectangle(vis, (int(b[0]), int(b[1])), (int(b[2]), int(b[3])), (90, 90, 90), 1)
        if getattr(tracker, 'last_win', None) is not None:
            b = tracker.last_win
            cv.rectangle(vis, (int(b[0]), int(b[1])), (int(b[2]), int(b[3])), (0, 200, 255), 1)
    if tracker.pts is not None and st in ('TRACK', 'POLL', 'ACQUIRE') and tracker.conf > 0:
        pts = tracker.pts
        if show_debug and tracker.bbox is not None:
            b = tracker.bbox
            cv.rectangle(vis, (int(b[0][0]), int(b[0][1])), (int(b[1][0]), int(b[1][1])), color, 2)
        for a, b_ in HAND_CONNECTIONS:
            cv.line(vis, tuple(pts[a].astype(int)), tuple(pts[b_].astype(int)), (255, 0, 0), 2)
        for i, p in enumerate(pts):
            cv.circle(vis, tuple(p.astype(int)), 3 if i else 6, (0, 0, 255) if i else (0, 255, 255), -1)
    age = (time.time() - tracker.last_result_time) * 1e3 if tracker.last_result_time else 0.0
    extra_lines = []
    tracker.ok = False
    if tracker.pts is not None and tracker.conf >= 0.6:
        mm, (r1, r2, r3) = palm_metrics(tracker.pts, args.palm_straight, args.palm_spread, args.palm_thumb)
        om, is_ok = ok_metrics(tracker.pts, args.ok_pinch, args.ok_straight, args.ok_span)
        if is_ok:
            verdict = 'OK hand (see ok line)'
        elif r3:
            verdict = 'OPEN PALM (spread)'
        elif r1:
            verdict = 'straight, NOT spread'
        else:
            verdict = 'fingers bent'
        extra_lines.append((f'palm: straight {mm["straight"]:4.2f}(<{args.palm_straight})  '
                            f'spread {mm["spread"]:5.1f}deg(>{args.palm_spread})  '
                            f'thumb {mm["thumb"]:4.2f}(>{args.palm_thumb})  -> {verdict}'
                            f'   [R1 {"Y" if r1 else "n"} R2 {"Y" if r2 else "n"} R3 {"Y" if r3 else "n"}]',
                            (0, 255, 0) if r3 else (0, 200, 255)))
        extra_lines.append((f'ok: pinch {om["pinch"]:4.2f}(<{args.ok_pinch})  '
                            f'3-finger straight {om["worst"]:4.2f}(<{args.ok_straight})  '
                            f'index span {om["span"]:4.2f}(>{args.ok_span})  '
                            f'-> {"OK" if is_ok else "--"}',
                            (0, 255, 0) if is_ok else (0, 200, 255)))
        tracker.ok = is_ok
    txt = [
        f'state={st}  conf={tracker.conf:.3f}  {"L" if tracker.handed > 0.5 else "R"}({tracker.handed:.2f})'
        f'  age {age:4.0f} ms',
        f'display {fps:4.1f} fps (no cap)   infer {inf_rate:4.1f}/s (cap {args.inf_per_sec})'
        f'   model {tracker.m.last_ms:4.1f} ms',
        f'total infer={tracker.total_inf}  locks={tracker.locks}  queue={len(tracker.queue)}'
        f'   crop={"rot" if tracker.m.rotate else "平移"}',
    ]
    lines = list(txt) + extra_lines
    for i, item in enumerate(lines):
        c, t = color, item
        if isinstance(item, tuple):
            t, c = item
        cv.putText(vis, t, (10, 26 + 24 * i), cv.FONT_HERSHEY_SIMPLEX, 0.62, (0, 0, 0), 4, cv.LINE_AA)
        cv.putText(vis, t, (10, 26 + 24 * i), cv.FONT_HERSHEY_SIMPLEX, 0.62, c, 1, cv.LINE_AA)
    return vis


def main(model_class=LiteLandmark, description='hand_landmark_lite 轮询+跟踪 demo'):
    ap = argparse.ArgumentParser(description=description)
    if model_class is LiteLandmark:
        ap.add_argument('--model', default=DEFAULT_MODEL)
    else:
        ap.set_defaults(model=None)
    ap.add_argument('--camera', type=int, default=0)
    ap.add_argument('--source', default=None, help='图片或视频文件（不给则用摄像头）')
    ap.add_argument('--width', type=int, default=1280)
    ap.add_argument('--height', type=int, default=720)
    ap.add_argument('--fps', type=int, default=60, help='向摄像头请求的帧率（显示不限帧，能跑多快跑多快）')
    ap.add_argument('--inf-per-sec', type=int, default=15, help='模型每秒计算多少张图（默认 15）')
    ap.add_argument('--coarse', type=float, nargs='+', default=[0.85, 0.60],
                    help='粗扫窗口边长 / 画面高（可给多个尺度）')
    ap.add_argument('--stride', type=float, default=0.35, help='粗扫窗口步长 / 边长（实测容忍半径≈0.15×边长）')
    ap.add_argument('--max-windows', type=int, default=0, help='每轮扫描窗口数上限，0=不截断（扫完整网格）')
    ap.add_argument('--crop-rotate', action='store_true',
                    help='跟踪裁剪按"手腕→中指根"旋转对齐（默认只平移；实测手基本竖直时不需要旋转）')
    ap.add_argument('--no-crop-rotate', action='store_true',
                    help=argparse.SUPPRESS)
    ap.add_argument('--t-poll', type=float, default=0.02, help='粗扫判定"这里可能有手"的置信度')
    ap.add_argument('--t-lock', type=float, default=0.75, help='锁定所需置信度')
    ap.add_argument('--t-lost', type=float, default=0.55, help='丢失判定置信度')
    ap.add_argument('--lost-frames', type=int, default=3)
    ap.add_argument('--acquire-max', type=int, default=12, help='收敛阶段最多迭代帧数')
    ap.add_argument('--palm-straight', type=float, default=1.20, help='五指判据：四指直度上限')
    ap.add_argument('--palm-spread', type=float, default=12.0, help='五指判据：相邻手指平均夹角下限（度）')
    ap.add_argument('--palm-thumb', type=float, default=0.90, help='五指判据：拇指尖-食指根/掌宽下限')
    ap.add_argument('--ok-pinch', type=float, default=0.45, help='OK 判据：拇指尖-食指尖/掌宽 上限')
    ap.add_argument('--ok-straight', type=float, default=1.30, help='OK 判据：中/无名/小指直度上限')
    ap.add_argument('--ok-span', type=float, default=0.25, help='OK 判据：食指根-食指尖/掌宽 下限（排除握拳）')
    ap.add_argument('--display-scale', type=float, default=0.0,
                    help='显示缩放（0=自动；窗口内始终等比，不会变形）')
    ap.add_argument('--headless', action='store_true', help='不开窗口（自测用）')
    ap.add_argument('--frames', type=int, default=0, help='headless 下跑多少帧后退出')
    ap.add_argument('--save-every', type=int, default=0, help='headless 下每 N 帧存一张标注图')
    ap.add_argument('--dump-dir', default='landmark_poll_shots')
    args = ap.parse_args()

    img = None
    IMG_EXT = ('.png', '.jpg', '.jpeg', '.bmp', '.webp')
    if args.source and args.source.lower().endswith(IMG_EXT):
        img = cv.imdecode(np.fromfile(args.source, dtype=np.uint8), cv.IMREAD_COLOR)
        if img is None:
            print(f'打不开图片: {args.source}')
            return 1
        cap, static = None, True
    elif args.source:
        cap = cv.VideoCapture(args.source)
        static = False
        if not cap.isOpened():
            print(f'打不开视频: {args.source}')
            return 1
    else:
        cap = cv.VideoCapture(args.camera, cv.CAP_DSHOW)
        if not cap.isOpened():
            cap = cv.VideoCapture(args.camera)
        cap.set(cv.CAP_PROP_FRAME_WIDTH, args.width)
        cap.set(cv.CAP_PROP_FRAME_HEIGHT, args.height)
        cap.set(cv.CAP_PROP_FPS, args.fps)
        static = False
        if not cap.isOpened():
            print(f'打不开摄像头 {args.camera}')
            return 1

    if static:
        w, h = img.shape[1], img.shape[0]
    else:
        ok, f0 = cap.read()
        if not ok:
            print('读不到画面')
            return 1
        h, w = f0.shape[:2]
    cam_fps = cap.get(cv.CAP_PROP_FPS) if (cap is not None) else 0.0
    cam_note = f'摄像头报告 {cam_fps:.0f} fps' if cam_fps and cam_fps > 1 else '摄像头未报帧率'
    model_name = os.path.basename(args.model) if args.model else 'FPGA integer emulator'
    print(f'输入 {w}x{h}（{cam_note}）  模型目标速率 {args.inf_per_sec} 张/秒  模型 {model_name}')

    model = model_class(args.model)
    model.rotate = bool(args.crop_rotate) and not args.no_crop_rotate
    print('跟踪裁剪：' + ('按手腕→中指根旋转对齐' if model.rotate else '只平移（不旋转）')
          + '   后端：' + getattr(model, 'backend_name',
                                'onnxruntime' if getattr(model, 'onnx', False)
                                else 'ai-edge-litert'), flush=True)
    tracker = PollTracker(model, w, h, args)
    worker = InferWorker(tracker, args)
    worker.start()
    print(f'推理限速 {args.inf_per_sec} 次/秒（最小间隔 {1000.0 / args.inf_per_sec:.1f} ms），显示不设上限')

    WIN = 'hand_landmark_lite poll+track'
    disp_w = disp_h = 0
    if not args.headless:
        scale = args.display_scale if args.display_scale > 0 else min(1.0, 1280.0 / w, 720.0 / h)
        disp_w, disp_h = max(320, int(w * scale)), max(180, int(h * scale))
        cv.namedWindow(WIN, cv.WINDOW_NORMAL)
        cv.resizeWindow(WIN, disp_w, disp_h)

    os.makedirs(args.dump_dir, exist_ok=True)
    # 等模型加载完、拿到第一帧尺寸后再进循环
    fid = 0
    t_start = time.perf_counter()
    t_prev = t_start
    fps = 0.0
    ok_prev = False
    while True:
        if static:
            frame = img.copy()
            time.sleep(1.0 / max(args.fps, 1))
        else:
            ok, frame = cap.read()
            if not ok:
                break
            if frame.shape[1] != w or frame.shape[0] != h:
                frame = fit_letterbox(frame, w, h)     # 等比，不拉伸
        fid += 1
        worker.submit(frame, fid)                      # 最新帧覆盖旧帧
        now = time.perf_counter()
        dt = now - t_prev
        t_prev = now
        fps = 0.9 * fps + 0.1 * (1.0 / dt if dt > 0 else 0)
        vis = draw(frame, tracker, args, fps, tracker.inf_rate(time.time()), True)
        if tracker.ok and not ok_prev:
            if tracker.pts is not None:
                om, _ = ok_metrics(tracker.pts, args.ok_pinch, args.ok_straight, args.ok_span)
                print(f'[ok] OK 手势  pinch={om["pinch"]:.2f} span={om["span"]:.2f} '
                      f'3-finger={om["worst"]:.2f}', flush=True)
            else:
                print('[ok] OK 手势', flush=True)
        ok_prev = tracker.ok
        if not args.headless:
            cw, ch = window_rect(WIN, (disp_w, disp_h))
            cv.imshow(WIN, fit_letterbox(vis, cw, ch))
            k = cv.waitKey(1) & 0xFF
            if k in (ord('q'), 27):
                break
            if k == ord('s'):
                p = os.path.join(args.dump_dir, f'shot_{int(time.time())}.png')
                cv.imwrite(p, vis)
                print('saved', p, flush=True)
            if k == ord('r'):
                tracker._build_sweep()
                tracker.pts = None
                tracker.conf = 0.0
        else:
            if args.save_every and fid % args.save_every == 0:
                cv.imencode('.png', vis)[1].tofile(os.path.join(args.dump_dir, f'f{fid:04d}.png'))
            if fid % 30 == 0:
                print(f'显示帧{fid:4d} 显示={fps:5.1f} fps 推理={tracker.inf_rate(time.time()):4.1f}/s '
                      f'state={tracker.state:7s} conf={tracker.conf:.3f} ok={"Y" if tracker.ok else "n"} '
                      f'模型={model.last_ms:4.1f}ms 累计={tracker.total_inf} 锁定={tracker.locks}', flush=True)
        if args.frames and fid >= args.frames:
            break
    worker.stop()
    if not static:
        cap.release()
    if not args.headless:
        cv.destroyAllWindows()
    wall = max(time.perf_counter() - t_start, 1e-6)
    print(f'\n结束：显示 {fid} 帧（{fid / wall:.1f} fps，不限帧率），'
          f'推理 {tracker.total_inf} 次（{tracker.total_inf / wall:.1f} 次/秒，上限 {args.inf_per_sec}），'
          f'锁定 {tracker.locks} 次')
    return 0


if __name__ == '__main__':
    sys.exit(main())
