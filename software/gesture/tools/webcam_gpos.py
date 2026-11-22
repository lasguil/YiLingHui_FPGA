"""Live hand-centre demo for `gpos_v1` on the local webcam.

This is the first view of the position model on its own domain. The validation
numbers say the centre is stable (about 3-6 px of jitter in a 720p frame) but
biased (about 105 px), and the bias is the number that decides whether a swipe
state machine can work: a constant offset cancels when the CPU differences the
position over time, a wandering one does not. Static images cannot answer that,
which is what this window is for.

What is on screen, and why:

  * the heatmap, upscaled and blended, so it is visible *where* the model looks,
    not just where its peak is;
  * a crosshair at the soft-argmax centre when the peak clears the threshold,
    and a dim mark of what it would have said when it does not -- so a refused
    frame still shows the model's opinion instead of nothing;
  * a trail of recent centres, which is literally the series the CPU will
    threshold;
  * a live jitter readout: the standard deviation of the centre over the last
    second, in frame pixels, over frames the model accepted. Hold your hand
    still and read it; that number against your screenshot threshold is the
    whole question.

The frame goes in whole: the model was trained on 16:9 frames, so a 16:9 camera
frame is a pure resize with no crop and no padding, and the centre maps back to
the frame by one scale factor.

CUDA is required and there is no CPU fallback.

Run from the repository root:
  python gesture/tools/webcam_gpos.py
  python gesture/tools/webcam_gpos.py --threshold 0.35 --record
  python gesture/tools/webcam_gpos.py --seconds 10 --headless --snapshot tmp/gpos_demo.png

Keys:
  q / ESC   quit
  space     pause / resume
  [ , ]     lower / raise the presence threshold by 0.05
  h         toggle the heatmap overlay
  t         toggle the centre trail
  i         toggle the model-input inset
  s         save a snapshot (frame + heatmap + one JSON row)
"""
import argparse
import json
import sys
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path

import numpy as np

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))

# Which checkpoint this window shows, and why it is not the presence-best one:
# measured on the validation split, the centre error is smallest around step
# 8,000 (18.7 canvas px = 94 px in a 720p frame at recall >= 0.95) and grows to
# 21.8 canvas px (109 px) by step 38,000, while presence AUC only creeps up by
# ~0.004 over the same span. The position task is what a swipe needs, so the
# selection criterion is the centre, which is what `best_centre.pt` records.
DEFAULT_CHECKPOINT = GESTURE / 'models' / 'gpos_v1' / 'best_centre.pt'
DEFAULT_THRESHOLD = 0.257
TRAIL_LENGTH = 90
HEAT_COLOUR = np.array([40.0, 60.0, 255.0])       # warm in BGR
CENTRE_COLOUR = (80, 255, 120)


def open_camera(cv2, index, width, height):
    """MSMF with MJPG first: DSHOW delivered 720p at 10 fps on this laptop."""
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
            return capture, name
        capture.release()
    raise SystemExit(f'cannot open camera index {index}')


class FrameGrabber:
    """Read the camera in a thread; the consumer always takes the newest frame."""

    def __init__(self, capture):
        self._capture = capture
        self._lock = threading.Lock()
        self._frame = None
        self._count = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self._stop.is_set():
            ok, frame = self._capture.read()
            if not ok or frame is None:
                time.sleep(0.01)
                continue
            with self._lock:
                self._frame = frame
                self._count += 1

    def start(self):
        self._thread.start()
        return self

    def latest(self):
        with self._lock:
            return self._frame, self._count, self._thread.is_alive()

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=1.0)


def heatmap_overlay(cv2, frame, probability):
    """Blend the heatmap into the frame, alpha following the probability.

    Plain numpy on purpose: the blend is the only expensive step in the loop and
    a straightforward version is the one that is easy to check by eye.
    """
    height, width = frame.shape[:2]
    grown = cv2.resize(probability.astype(np.float32), (width, height),
                       interpolation=cv2.INTER_LINEAR)
    alpha = np.clip(grown, 0.0, 1.0)[:, :, None] * 0.55
    tinted = (frame.astype(np.float32) * (1 - alpha)
              + HEAT_COLOUR[None, None, :] * alpha)
    return tinted.astype(np.uint8)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--checkpoint', type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument('--camera', type=int, default=0)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--threshold', type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument('--width', type=int, default=1280)
    parser.add_argument('--height', type=int, default=720)
    parser.add_argument('--seconds', type=float, default=0.0, help='0 = until quit')
    parser.add_argument('--max-frames', type=int, default=0)
    parser.add_argument('--headless', action='store_true')
    parser.add_argument('--record', action='store_true',
                        help='write one JSON line per frame into the session dir')
    parser.add_argument('--image', type=Path,
                        help='run one still image instead of the camera: a '
                             'deterministic check of where the centre lands')
    parser.add_argument('--snapshot', type=Path)
    parser.add_argument('--session', default=None)
    args = parser.parse_args()

    import cv2
    import torch
    from PIL import Image

    from src.position import peak_and_centre
    from src.preprocess import preprocess_image
    from src.spec import load_config
    from src.train import load_model_from_checkpoint

    if not args.device.startswith('cuda'):
        raise SystemExit('an explicit CUDA device is required, e.g. --device cuda:0')
    if not torch.cuda.is_available():
        raise SystemExit('torch reports no CUDA device; this demo has no CPU path')
    device = torch.device(args.device)
    if device.index is None or device.index >= torch.cuda.device_count():
        raise SystemExit(f'bad device index: {args.device}')
    if not args.checkpoint.is_file():
        raise SystemExit(f'missing checkpoint: {args.checkpoint}')

    model_config = GESTURE / 'configs' / 'gpos_v1.json'
    spec = load_config(model_config)
    model, step, metrics, run_config = load_model_from_checkpoint(args.checkpoint, device)
    model.eval()
    print(f'torch {torch.__version__}  device {device}  '
          f'{torch.cuda.get_device_name(device)}')
    print(f'checkpoint {args.checkpoint.name}  step {step}  '
          f'input {spec["input"]["width"]}x{spec["input"]["height"]}  '
          f'threshold {args.threshold:.3f}')
    if metrics:
        print(f'  recorded at save time: ' + json.dumps(
            {k: v for k, v in metrics.items() if k != 'centre_at_recall_floor'},
            ensure_ascii=False))

    session = args.session or datetime.now().strftime('%Y%m%d_%H%M%S')
    session_dir = GESTURE / 'camera_sessions' / f'gpos_{session}'
    session_dir.mkdir(parents=True, exist_ok=True)
    print(f'session -> {session_dir}')
    recorder = ((session_dir / 'frames.jsonl').open('w', encoding='utf-8')
                if args.record else None)

    if args.image is not None:
        # One still frame through exactly the inference path the camera loop uses,
        # so the answer can be checked against the picture instead of a memory of
        # what the webcam was pointing at.
        frame = cv2.imread(str(args.image))
        if frame is None:
            raise SystemExit(f'cannot read {args.image}')
        array, _ = preprocess_image(
            Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)), spec)
        with torch.inference_mode():
            logits = model(torch.from_numpy(array).unsqueeze(0).to(device))
        peak, centre = peak_and_centre(logits)
        peak = float(peak[0])
        height, width = frame.shape[:2]
        x, y = float(centre[0, 0]) * width, float(centre[0, 1]) * height
        display = heatmap_overlay(cv2, frame.copy(), torch.sigmoid(logits)[0, 0].cpu().numpy())
        colour = CENTRE_COLOUR if peak >= threshold else (120, 120, 120)
        cv2.drawMarker(display, (int(x), int(y)), colour, cv2.MARKER_CROSS, 26, 2)
        cv2.rectangle(display, (0, 0), (display.shape[1], 30), (0, 0, 0), -1)
        cv2.putText(display, f'{args.image.name}  peak {peak:.3f}  thr {threshold:.2f}  '
                             f'{"HAND" if peak >= threshold else "no hand"}  '
                             f'centre {x:.1f},{y:.1f} px',
                    (8, 21), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (235, 235, 235), 1, cv2.LINE_AA)
        print(f'{args.image}: peak {peak:.4f}  centre ({x:.1f}, {y:.1f}) px  '
              f'{"HAND" if peak >= threshold else "no hand"}  (threshold {threshold})')
        if args.snapshot is not None:
            args.snapshot.parent.mkdir(parents=True, exist_ok=True)
            cv2.imwrite(str(args.snapshot), display)
            print(f'snapshot -> {args.snapshot}')
        if not args.headless:
            cv2.imshow('gpos hand centre', display)
            cv2.waitKey(0)
        cv2.destroyAllWindows()
        return 0

    capture, backend = open_camera(cv2, args.camera, args.width, args.height)
    grabber = FrameGrabber(capture).start()
    capture_mark = (time.perf_counter(), 0)
    print(f'camera {args.camera} via {backend}')
    if not args.headless:
        cv2.namedWindow('gpos hand centre', cv2.WINDOW_NORMAL)
        cv2.resizeWindow('gpos hand centre', min(args.width, 1280),
                         min(args.height, 800))

    threshold = args.threshold
    show_heatmap = show_trail = show_inset = True
    paused = False
    trail = deque(maxlen=TRAIL_LENGTH)
    jitter_window = deque()          # (time, x, y) of accepted frames
    seen = -1
    frames = 0
    display = None
    inference_ms = 0.0
    cam_fps = disp_fps = 0.0
    rate_marks = deque(maxlen=60)
    stopped = False
    started = time.perf_counter()
    try:
        while not stopped:
            if not paused:
                frame, count, alive = grabber.latest()
                if frame is None or count == seen:
                    if not alive:
                        print('camera reader stopped')
                        break
                    time.sleep(0.002)
                    continue
                seen = count
                # PIL in, the same path the training pipeline takes: the resize
                # contract is PIL bilinear, not OpenCV's.
                array, _ = preprocess_image(
                    Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)), spec)
                tensor = torch.from_numpy(array).unsqueeze(0).to(device)
                began = time.perf_counter()
                with torch.inference_mode():
                    logits = model(tensor)
                inference_ms = (time.perf_counter() - began) * 1000
                peak, centre = peak_and_centre(logits)
                peak = float(peak[0])
                probability = torch.sigmoid(logits)[0, 0].cpu().numpy()
                frames += 1

                height, width = frame.shape[:2]
                x = float(centre[0, 0]) * width
                y = float(centre[0, 1]) * height
                now = time.perf_counter()
                accepted = peak >= threshold
                if accepted:
                    trail.append((x, y, peak))
                    jitter_window.append((now, x, y))
                while jitter_window and jitter_window[0][0] < now - 1.0:
                    jitter_window.popleft()
                rate_marks.append(now)
                if now - capture_mark[0] >= 0.5:
                    cam_fps = (count - capture_mark[1]) / (now - capture_mark[0])
                    capture_mark = (now, count)
                while rate_marks and rate_marks[0] < now - 1.0:
                    rate_marks.popleft()
                disp_fps = max(len(rate_marks) - 1, 0) / max(
                    rate_marks[-1] - rate_marks[0], 1e-6) if len(rate_marks) > 2 else 0.0

                display = frame.copy()
                if show_heatmap:
                    display = heatmap_overlay(cv2, display, probability)
                if show_trail and len(trail) > 1:
                    points = np.array([[int(px), int(py)] for px, py, _ in trail])
                    for index in range(1, len(points)):
                        shade = 60 + int(180 * index / len(points))
                        cv2.line(display, tuple(points[index - 1]), tuple(points[index]),
                                 (shade // 3, shade, shade // 3), 2, cv2.LINE_AA)
                colour = CENTRE_COLOUR if accepted else (120, 120, 120)
                cv2.drawMarker(display, (int(x), int(y)), colour, cv2.MARKER_CROSS, 22, 2)
                if accepted:
                    cv2.circle(display, (int(x), int(y)), 14, colour, 1)

                jitter = ''
                if len(jitter_window) > 5:
                    xs = np.array([p[1] for p in jitter_window])
                    ys = np.array([p[2] for p in jitter_window])
                    jitter = (f'  jitter {xs.std():4.1f}/{ys.std():4.1f} px '
                              f'({len(jitter_window)} frames)')
                status = (f'gpos_v1 step {step}  peak {peak:5.3f}  thr {threshold:.2f}  '
                          f'{"HAND" if accepted else "    "}  '
                          f'centre {x:6.1f},{y:6.1f} px  inf {inference_ms:4.1f} ms  '
                          f'{disp_fps:4.1f} fps{jitter}')
                cv2.rectangle(display, (0, 0), (display.shape[1], 28), (0, 0, 0), -1)
                cv2.putText(display, status, (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                            (235, 235, 235), 1, cv2.LINE_AA)

                # The verdict itself, large and colour-coded: the peak against
                # the threshold is the decision, and it should not have to be
                # read out of a status line.
                verdict = 'HAND' if accepted else 'no hand'
                tint = (60, 200, 60) if accepted else (70, 70, 70)
                box_w = 190
                cv2.rectangle(display, (0, 28), (box_w, 86), tint, -1)
                cv2.putText(display, verdict, (10, 70), cv2.FONT_HERSHEY_SIMPLEX, 1.1,
                            (0, 0, 0) if accepted else (200, 200, 200), 2, cv2.LINE_AA)
                # A bar makes the margin visible: fill is the peak, the tick is
                # the threshold, the end of the bar is twice the threshold.
                bar_x, bar_y, bar_w, bar_h = box_w + 10, 40, 200, 16
                span = max(threshold * 2.0, 1e-6)
                fill = int(bar_w * min(peak / span, 1.0))
                cv2.rectangle(display, (bar_x, bar_y), (bar_x + bar_w, bar_y + bar_h),
                              (40, 40, 40), -1)
                cv2.rectangle(display, (bar_x, bar_y), (bar_x + fill, bar_y + bar_h),
                              (60, 200, 60) if accepted else (140, 140, 140), -1)
                tick = bar_x + int(bar_w * min(threshold / span, 1.0))
                cv2.line(display, (tick, bar_y - 4), (tick, bar_y + bar_h + 4),
                         (255, 255, 255), 2)
                cv2.putText(display, f'peak {peak:.3f} / threshold {threshold:.3f}',
                            (bar_x, bar_y + bar_h + 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                            (235, 235, 235), 1, cv2.LINE_AA)
                if show_inset:
                    # The tensor itself, denormalised: this is what the network
                    # saw, overlays and all excluded.
                    model_input = ((array.transpose(1, 2, 0) * 128.0) + 128.0)
                    model_input = np.clip(model_input, 0, 255).astype(np.uint8)
                    insert = cv2.cvtColor(model_input, cv2.COLOR_RGB2BGR)
                    inset = cv2.resize(insert, (spec['input']['width'] * 2,
                                                spec['input']['height'] * 2),
                                       interpolation=cv2.INTER_NEAREST)
                    y0 = display.shape[0] - inset.shape[0] - 6
                    display[y0:y0 + inset.shape[0], 0:inset.shape[1]] = inset
                    cv2.putText(display, 'model input 256x144 (x2)', (4, y0 - 4),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.45, (180, 180, 180), 1)
                if recorder is not None:
                    recorder.write(json.dumps(dict(
                        t=round(now - started, 4), peak=round(peak, 6),
                        accepted=bool(accepted), x_px=round(x, 2), y_px=round(y, 2),
                        inference_ms=round(inference_ms, 3))) + '\n')

            if args.max_frames and frames >= args.max_frames:
                break
            if args.seconds and time.perf_counter() - started >= args.seconds:
                break
            if args.headless or display is None:
                continue

            cv2.imshow('gpos hand centre', display)
            key = cv2.waitKey(1) & 0xFF
            if key in (ord('q'), 27):
                stopped = True
            elif key == ord(' '):
                paused = not paused
            elif key == ord('['):
                threshold = round(max(0.0, threshold - 0.05), 2)
            elif key == ord(']'):
                threshold = round(min(0.99, threshold + 0.05), 2)
            elif key == ord('h'):
                show_heatmap = not show_heatmap
            elif key == ord('t'):
                show_trail = not show_trail
                trail.clear()
            elif key == ord('i'):
                show_inset = not show_inset
            elif key == ord('s') and display is not None:
                stamp = datetime.now().strftime('%H%M%S_%f')[:-3]
                cv2.imwrite(str(session_dir / f'frame_{stamp}.png'), display)
                with (session_dir / 'snapshots.jsonl').open('a', encoding='utf-8') as fh:
                    fh.write(json.dumps(dict(file=f'frame_{stamp}.png',
                                             threshold=threshold, **{
                                                 k: float(v) for k, v in
                                                 (('peak', peak), ('x_px', x),
                                                  ('y_px', y))})) + '\n')
                print(f'saved {session_dir}/frame_{stamp}.png')
    finally:
        grabber.stop()
        capture.release()
        cv2.destroyAllWindows()
        if recorder is not None:
            recorder.close()

    if args.snapshot is not None and display is not None:
        args.snapshot.parent.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(args.snapshot), display)
        print(f'snapshot -> {args.snapshot}')
    print(f'frames {frames}  inference {inference_ms:.1f} ms  camera {cam_fps:.1f}  '
          f'display {disp_fps:.1f} fps  accepted {len(trail)} of last {len(trail)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
