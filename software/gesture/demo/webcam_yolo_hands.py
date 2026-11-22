"""Live YOLOv10n hand detection on the local webcam.

This is the PC-side reference for `models/teacher_hagrid/YOLOv10n_hands.pt`, the
HaGRID-trained hand detector the repository keeps as an offline teacher (hand
area measurement for sampling weights) and explicitly does not deploy. Running it
live is how the gap is made visible: 8.5 GFLOPs per 640x640 frame is about 440x
the per-frame cost of the four-class model, so what this window shows is the
upper bound a PC GPU sets, never a board estimate.

The numbers printed on screen come from this run on this machine, no constant
stands in for them. `inf` is the forward pass the inference library measured;
`cam` is the capture rate the camera sustains; `disp` is the rate the operator
sees. Capture runs in its own thread so it overlaps inference and `disp` follows
the camera instead of being the sum of the two.

Two hardware facts the defaults now encode, both measured on this laptop on
2026-10-16:
  * OpenCV's DSHOW backend delivers 720p uncompressed at ~10 fps (96 ms/frame);
    MSMF with an MJPG request sustains the camera's real 30 fps (34 ms/frame).
  * The GPU needs several seconds to leave its idle clock state: the same
    forward pass measures ~25 ms cold and ~12.5 ms warm, and `quantize` fp16
    versus fp32 makes no difference once warm. The warm-up loop below exists so
    the first seconds of the window are not mistaken for the model's speed.

Two things about the checkpoint itself, both measured on 2026-10-16:
  * It was trained with `single_cls`, so it detects "a hand" and nothing finer,
    but its 34 output names are still the leftover HaGRID gesture names: read
    raw, an open palm comes back as `grabbing 0.90`. The overlay prints `hand`
    because that is what the weights mean.
  * Its one-to-one head (`nms=False`) returns one box per hand; the classic NMS
    path returns nested duplicates on a single hand (3 boxes for one palm at
    IoU 0.7, 1 box with the one-to-one head). `--nms` switches to the latter.

Unlike the four-class demo in `tools/webcam_demo.py`, this detector runs on the
whole frame: localising the hand is what it is for, so no crop is imposed.

CUDA is required and there is no CPU fallback.

Run from the repository root (unset PYTHONHOME/PYTHONPATH first if Efinity's
setup.bat is in the environment):
  python gesture/demo/webcam_yolo_hands.py
  python gesture/demo/webcam_yolo_hands.py --camera 1 --conf 0.4
  python gesture/demo/webcam_yolo_hands.py --seconds 10 --headless \
      --snapshot gesture/demo/samples/yolo_hands_snapshot.png

Keys:
  q / ESC   quit
  space     pause / resume
  s         save the current annotated frame into the session directory
  b         toggle boxes
  [ , ]     lower / raise the confidence threshold by 0.05
"""
import argparse
import sys
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
DEFAULT_WEIGHTS = GESTURE / 'models/teacher_hagrid/YOLOv10n_hands.pt'
BOX_COLOUR = (60, 200, 90)
TEXT_COLOUR = (235, 235, 235)
WARMUP_FRAMES = 10


def open_camera(cv2, index, width, height):
    """Prefer the backend that actually reaches the camera's frame rate.

    MSMF with MJPG is first because it does; DSHOW is kept as the fallback the
    rest of the repository uses. The first backend that returns a frame wins, so
    a machine where MSMF is missing still gets a picture.
    """
    for name, backend in (('MSMF', cv2.CAP_MSMF), ('DSHOW', cv2.CAP_DSHOW),
                          ('ANY', cv2.CAP_ANY)):
        capture = cv2.VideoCapture(index, backend)
        if not capture.isOpened():
            capture.release()
            continue
        capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
        capture.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        capture.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        capture.set(cv2.CAP_PROP_FPS, 30)
        ok, frame = capture.read()
        if ok and frame is not None:
            return capture, name, frame
        print(f'  {name} opened but returned no frame; trying the next backend')
        capture.release()
    raise SystemExit(f'cannot open camera index {index}')


class FrameGrabber:
    """Reads the camera in a thread and keeps only the newest frame.

    Inference takes about as long as the camera takes to produce a frame, so a
    sequential loop would halve the displayed rate and always show a stale
    picture. The reader instead runs ahead, and the consumer takes whatever is
    newest when it becomes free, skipping anything captured meanwhile.
    """

    def __init__(self, capture):
        self._capture = capture
        self._lock = threading.Lock()
        self._frame = None
        self._count = 0
        self._failures = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self._stop.is_set():
            ok, frame = self._capture.read()
            if not ok or frame is None:
                self._failures += 1
                if self._failures > 30:
                    print('camera stopped delivering frames')
                    self._stop.set()
                time.sleep(0.01)
                continue
            self._failures = 0
            with self._lock:
                self._frame = frame
                self._count += 1

    def start(self):
        self._thread.start()
        return self

    def latest(self):
        """Newest frame, how many were captured, and 0 if the reader has died."""
        with self._lock:
            alive = self._thread.is_alive()
            return self._frame, self._count, alive

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=1.0)


def label_for(names, class_id, single_class):
    """The name to print for a detection.

    A checkpoint trained with `single_cls` has one real class, but its head
    keeps the original names, so the raw label of a plain open hand reads
    `grabbing`. Reporting the trained meaning is the honest option.
    """
    if single_class:
        return 'hand'
    if isinstance(names, dict):
        return str(names.get(int(class_id), class_id))
    if isinstance(names, (list, tuple)) and int(class_id) < len(names):
        return str(names[int(class_id)])
    return str(class_id)


def draw(cv2, frame, boxes, names, single_class, show_boxes, status):
    """Draw detector boxes and the status line onto `frame` (a copy)."""
    if boxes is not None and show_boxes:
        for box in boxes.xyxy:
            x1, y1, x2, y2 = (int(v) for v in box)
            cv2.rectangle(frame, (x1, y1), (x2, y2), BOX_COLOUR, 2)
        for box, score, class_id in zip(boxes.xyxy, boxes.conf, boxes.cls):
            x1, y1 = int(box[0]), int(box[1])
            text = f'{label_for(names, class_id, single_class)} {float(score):.2f}'
            cv2.putText(frame, text, (x1, max(18, y1 - 8)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, BOX_COLOUR, 2, cv2.LINE_AA)

    cv2.rectangle(frame, (0, 0), (frame.shape[1], 30), (0, 0, 0), -1)
    cv2.putText(frame, status, (8, 21), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                TEXT_COLOUR, 1, cv2.LINE_AA)
    return frame


class Rate:
    """Frames per second over a sliding window, from the marks of that source."""

    def __init__(self, window=1.0):
        self._window = window
        self._times = deque()
        self._last_count = None

    def update(self, count, now):
        if self._last_count is not None and count == self._last_count:
            return self.rate(now)
        if self._last_count is None:
            self._last_count = count
            self._times.append(now)
            return 0.0
        self._last_count = count
        self._times.append(now)
        while len(self._times) > 1 and self._times[0] < now - self._window:
            self._times.popleft()
        return self.rate(now)

    def rate(self, now):
        if len(self._times) < 2:
            return 0.0
        span = now - self._times[0]
        return (len(self._times) - 1) / span if span > 0 else 0.0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--weights', type=Path, default=DEFAULT_WEIGHTS)
    parser.add_argument('--camera', type=int, default=0)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--conf', type=float, default=0.25,
                        help='detection confidence threshold')
    parser.add_argument('--imgsz', type=int, default=640,
                        help="the checkpoint's own 640; override only to test")
    parser.add_argument('--precision', choices=['fp16', 'fp32'], default='fp16')
    parser.add_argument('--nms', action='store_true',
                        help='classic NMS postprocess (nested duplicates on one '
                             'hand) instead of the one-to-one head')
    parser.add_argument('--iou', type=float, default=0.45,
                        help='NMS IoU threshold; only used with --nms')
    parser.add_argument('--width', type=int, default=1280)
    parser.add_argument('--height', type=int, default=720)
    parser.add_argument('--seconds', type=float, default=0.0,
                        help='run this long then exit (0 = until quit)')
    parser.add_argument('--max-frames', type=int, default=0,
                        help='infer this many frames then exit (0 = until quit)')
    parser.add_argument('--headless', action='store_true',
                        help='no window, no keys; for scripted checks')
    parser.add_argument('--no-thread', dest='threaded', action='store_false',
                        help='read the camera inline instead of in a thread')
    parser.add_argument('--snapshot', type=Path, default=None,
                        help='write the last annotated frame here')
    parser.add_argument('--session', default=None,
                        help='session directory name under gesture/camera_sessions')
    args = parser.parse_args()

    import cv2
    import torch
    from ultralytics import YOLO

    if not args.device.startswith('cuda'):
        raise SystemExit('an explicit CUDA device is required, e.g. --device cuda:0')
    if not torch.cuda.is_available():
        raise SystemExit('torch reports no CUDA device; this demo has no CPU path')
    device = torch.device(args.device)
    if device.index is None or device.index >= torch.cuda.device_count():
        raise SystemExit(f'bad device index: {args.device}')
    if not args.weights.is_file():
        raise SystemExit(f'missing weights: {args.weights}')

    print(f'torch {torch.__version__}  device {device}  '
          f'{torch.cuda.get_device_name(device)}')
    model = YOLO(str(args.weights))
    single_class = bool((getattr(model.model, 'args', None) or {}).get('single_cls'))
    print(f'weights {args.weights.relative_to(GESTURE.parent)}  '
          f'classes {len(model.names)}'
          f'{" (trained single_cls)" if single_class else ""}  '
          f'precision {args.precision}  postprocess '
          f'{"NMS iou " + str(args.iou) if args.nms else "one-to-one head"}')

    session = args.session or datetime.now().strftime('%Y%m%d_%H%M%S')
    session_dir = GESTURE / 'camera_sessions' / session
    session_dir.mkdir(parents=True, exist_ok=True)
    print(f'snapshots -> {session_dir}')

    quantize = 16 if args.precision == 'fp16' else 32

    def infer(frame):
        """One forward pass; the result's speed dict is the library's own timing."""
        with torch.inference_mode():
            return model.predict(frame, imgsz=args.imgsz, conf=args.conf,
                                 device=device.index, quantize=quantize,
                                 nms=args.nms, iou=args.iou,
                                 verbose=False)[0]

    capture, backend_name, first = open_camera(cv2, args.camera, args.width,
                                               args.height)
    height, width = first.shape[:2]
    print(f'camera {args.camera} via {backend_name}  {width}x{height}')

    # Ramp the GPU clock out of idle and build the inference engine before any
    # number is reported; cold measurements are roughly twice as slow.
    warmup_started = time.perf_counter()
    for _ in range(WARMUP_FRAMES):
        infer(first)
    print(f'warm-up {WARMUP_FRAMES} frames in '
          f'{time.perf_counter() - warmup_started:.2f} s')

    grabber = FrameGrabber(capture).start() if args.threaded else None

    if not args.headless:
        cv2.namedWindow('yolo hands', cv2.WINDOW_NORMAL)
        cv2.resizeWindow('yolo hands', min(width, 1280), min(height, 800))

    started = time.perf_counter()
    captured = 0
    inferred = 0
    saved = 0
    paused = False
    show_boxes = True
    inference_ms = 0.0
    boxes = None
    display = None
    seen = -1
    capture_rate, inference_rate = Rate(), Rate()
    cam_fps = disp_fps = 0.0
    stopped = False
    try:
        while not stopped:
            if not paused:
                if grabber is not None:
                    frame, captured, alive = grabber.latest()
                    if frame is None or captured == seen:
                        if not alive:
                            print('camera reader stopped; stopping')
                            break
                        time.sleep(0.001)
                        continue
                    seen = captured
                else:
                    ok, frame = capture.read()
                    if not ok:
                        print('camera read failed; stopping')
                        break
                    captured += 1

                now = time.perf_counter()
                cam_fps = capture_rate.update(captured, now)

                result = infer(frame)
                inference_ms = float(result.speed['inference'])
                boxes = result.boxes
                inferred += 1
                now = time.perf_counter()
                disp_fps = inference_rate.update(inferred, now)
                display = draw(cv2, frame.copy(), boxes, model.names, single_class,
                               show_boxes,
                               f'YOLOv10n hands live  inf {inference_ms:5.1f} ms  '
                               f'cam {cam_fps:4.1f} fps  disp {disp_fps:4.1f} fps  '
                               f'conf>={args.conf:.2f}  hands {len(boxes)}')
            elif display is not None:
                display = draw(cv2, frame.copy(), boxes, model.names, single_class,
                               show_boxes,
                               f'YOLOv10n hands PAUSED  inf {inference_ms:5.1f} ms  '
                               f'conf>={args.conf:.2f}  '
                               f'hands {0 if boxes is None else len(boxes)}')

            if args.max_frames and inferred >= args.max_frames:
                break
            if args.seconds and time.perf_counter() - started >= args.seconds:
                break
            if args.headless:
                continue

            cv2.imshow('yolo hands', display)
            key = cv2.waitKey(1) & 0xFF
            if key in (ord('q'), 27):
                stopped = True
            elif key == ord(' '):
                paused = not paused
            elif key == ord('b'):
                show_boxes = not show_boxes
            elif key == ord('['):
                args.conf = round(max(0.0, args.conf - 0.05), 2)
            elif key == ord(']'):
                args.conf = round(min(0.95, args.conf + 0.05), 2)
            elif key == ord('s') and display is not None:
                stamp = datetime.now().strftime('%H%M%S_%f')[:-3]
                out = session_dir / f'yolo_{stamp}.jpg'
                cv2.imwrite(str(out), display)
                saved += 1
                print(f'saved {out.relative_to(GESTURE.parent)}')
    finally:
        if grabber is not None:
            grabber.stop()
        capture.release()
        cv2.destroyAllWindows()

    if args.snapshot is not None and display is not None:
        args.snapshot.parent.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(args.snapshot), display)
        print(f'snapshot -> {args.snapshot}')

    wall = time.perf_counter() - started
    print(f'inferred {inferred} frames in {wall:.1f} s ({inferred / wall:.1f} fps)  '
          f'captured {captured}  last inference {inference_ms:.1f} ms  '
          f'camera {cam_fps:.1f} fps  display {disp_fps:.1f} fps')
    print(f'snapshots {saved} in {session_dir}')


if __name__ == '__main__':
    main()
