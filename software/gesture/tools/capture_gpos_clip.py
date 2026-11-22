"""Record a short same-domain clip for fine-tuning `gpos_v1` on the real camera.

Why this exists: the training data is HaGRID hand-centred crops plus COCO scenes,
so "a close-up head with no hand in frame" is a negative the model has never
seen, and it answers by putting a peak on the face. No amount of threshold
tuning invents that negative -- it has to come from the camera that will be used.
Two minutes here is worth more than another 40,000 steps on the old data.

What it records, and why that shape:

  * the **full camera frame** as JPEG, not the 256x144 model input. The frames go
    through the same preprocessing as training (`preprocess_image`), so the
    fine-tune sees exactly what inference sees, and the raw frames stay reusable
    for the CPU-side state machine and for re-labelling later.
  * one line per frame in `session.jsonl` with the class you pressed and the
    current model's peak, which is the before/after comparison: the false
    positive rate on the negatives before fine-tuning is measured from this file.

Protocol (aim for about 25 s per class, moving around):

  1  toggle recording NEGATIVES: head and shoulders in frame, hands out of frame
     or down at your side. Move your head as you would while using the device,
     and include the lighting you will actually be in.
  2  toggle recording POSITIVES: one hand in frame, held up, then move it up and
     down and left and right as if swiping. Keep it in the middle of the frame.
  space  pause, s  snapshot the current view, q  quit

Run from the repository root:
  $env:PYTHONHOME=$null; $env:PYTHONPATH=$null
  & 'C:\\Users\\29966\\AppData\\Local\\Programs\\Python\\Python312\\python.exe' `
      gesture/tools/capture_gpos_clip.py
"""
import argparse
import json
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import numpy as np

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))

CLASS_KEYS = {'1': 'no_hand', '2': 'hand'}
DEFAULT_CHECKPOINT = GESTURE / 'models' / 'gpos_v1' / 'best_presence.pt'


def open_camera(cv2, index, width, height):
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


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--checkpoint', type=Path, default=DEFAULT_CHECKPOINT,
                        help='the model whose peaks are logged alongside the frames')
    parser.add_argument('--camera', type=int, default=0)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--threshold', type=float, default=0.257)
    parser.add_argument('--every', type=int, default=3,
                        help='save every Nth frame while recording (~10 fps at 30fps)')
    parser.add_argument('--width', type=int, default=1280)
    parser.add_argument('--height', type=int, default=720)
    parser.add_argument('--session', default=None)
    parser.add_argument('--headless', action='store_true')
    parser.add_argument('--seconds', type=float, default=0.0)
    parser.add_argument('--auto-record', default='',
                        help='comma list of class keys to cycle while headless, e.g. "1,2"')
    args = parser.parse_args()

    import cv2
    import torch
    from PIL import Image

    from src.position import peak_and_centre
    from src.preprocess import preprocess_image
    from src.spec import load_config
    from src.train import load_model_from_checkpoint

    if not torch.cuda.is_available():
        raise SystemExit('CUDA required; no CPU fallback')
    device = torch.device(args.device)
    spec = load_config(GESTURE / 'configs' / 'gpos_v1.json')
    model, step, _, _ = load_model_from_checkpoint(args.checkpoint, device)
    model.eval()
    print(f'peak model: {args.checkpoint.name} step {step} on '
          f'{torch.cuda.get_device_name(device)}')

    session = args.session or datetime.now().strftime('%Y%m%d_%H%M%S')
    session_dir = GESTURE / 'camera_sessions' / f'clip_{session}'
    for key in CLASS_KEYS.values():
        (session_dir / 'frames' / key).mkdir(parents=True, exist_ok=True)
    log_path = session_dir / 'session.jsonl'
    print(f'session -> {session_dir}')

    capture, backend = open_camera(cv2, args.camera, args.width, args.height)
    print(f'camera {args.camera} via {backend}  {args.width}x{args.height}')
    if not args.headless:
        cv2.namedWindow('capture clip', cv2.WINDOW_NORMAL)

    recording = {key: False for key in CLASS_KEYS}
    counts = {key: 0 for key in CLASS_KEYS}
    auto = [key for key in args.auto_record.split(',') if key in CLASS_KEYS]
    auto_until = time.perf_counter() + 8.0 if auto else None
    frame_index = 0
    saved = 0
    started = time.perf_counter()
    peak = 0.0
    display = None
    with log_path.open('w', encoding='utf-8') as log:
        try:
            while True:
                if args.seconds and time.perf_counter() - started >= args.seconds:
                    break
                if auto and auto_until is not None and time.perf_counter() > auto_until:
                    # headless rehearsal: alternate the two classes every 8 s
                    current = [k for k in recording if recording[k]]
                    for key in current:
                        recording[key] = False
                    next_key = auto[(auto.index(current[0]) + 1) % len(auto)] if current else auto[0]
                    recording[next_key] = True
                    auto_until = time.perf_counter() + 8.0
                    print(f'auto-record -> {CLASS_KEYS[next_key]}')
                ok, frame = capture.read()
                if not ok:
                    time.sleep(0.01)
                    continue
                frame_index += 1
                array, _ = preprocess_image(
                    Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)), spec)
                with torch.inference_mode():
                    logits = model(torch.from_numpy(array).unsqueeze(0).to(device))
                peak, centre = peak_and_centre(logits)
                peak = float(peak[0])
                x = float(centre[0, 0]) * frame.shape[1]
                y = float(centre[0, 1]) * frame.shape[0]

                active = [key for key in CLASS_KEYS if recording[key]]
                if active and frame_index % args.every == 0:
                    path = (session_dir / 'frames' / CLASS_KEYS[active[0]] /
                            f'{datetime.now().strftime("%H%M%S_%f")[:-3]}.jpg')
                    cv2.imwrite(str(path), frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
                    log.write(json.dumps(dict(
                        file=str(path.relative_to(session_dir)), label=CLASS_KEYS[active[0]],
                        peak=round(peak, 6), x_px=round(x, 2), y_px=round(y, 2),
                        t=round(time.perf_counter() - started, 3))) + '\n')
                    counts[active[0]] += 1
                    saved += 1
                    log.flush()

                display = frame.copy()
                colour = (60, 200, 60) if peak >= args.threshold else (90, 90, 90)
                cv2.drawMarker(display, (int(x), int(y)), colour, cv2.MARKER_CROSS, 22, 2)
                banner = ' + '.join(f'REC {CLASS_KEYS[k]} {counts[k]}'
                                    for k in CLASS_KEYS if recording[k]) or 'idle'
                cv2.rectangle(display, (0, 0), (display.shape[1], 34), (0, 0, 0), -1)
                cv2.putText(display, f'{banner}   peak {peak:.3f}   saved {saved}',
                            (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                            (0, 200, 0) if active else (235, 235, 235), 2, cv2.LINE_AA)
                cv2.putText(display,
                            '1 = no-hand negatives   2 = hand positives   space pause   q quit',
                            (8, display.shape[0] - 12), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                            (235, 235, 235), 1, cv2.LINE_AA)
                if args.headless:
                    continue
                cv2.imshow('capture clip', display)
                key = cv2.waitKey(1) & 0xFF
                if key in (ord('q'), 27):
                    break
                if chr(key) in CLASS_KEYS:
                    name = CLASS_KEYS[chr(key)]
                    recording[name] = not recording[name]
                    print(f'{name}: {"recording" if recording[name] else "stopped"} '
                          f'({counts[name]} frames)')
                elif key == ord('s') and display is not None:
                    stamp = datetime.now().strftime('%H%M%S')
                    cv2.imwrite(str(session_dir / f'view_{stamp}.png'), display)
        finally:
            capture.release()
            cv2.destroyAllWindows()

    summary = dict(session=str(session_dir), checkpoint=str(args.checkpoint),
                   model_step=step, saved=saved,
                   counts={CLASS_KEYS[k]: counts[k] for k in CLASS_KEYS},
                   threshold=args.threshold, camera=f'{args.width}x{args.height}')
    (session_dir / 'summary.json').write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False))
    print(f'下一件事：把 {session_dir} 传给我（或告诉我路径），我在服务器上跑教师标注 + 微调')
    return 0


if __name__ == '__main__':
    sys.exit(main())
