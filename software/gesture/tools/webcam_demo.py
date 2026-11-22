"""Live four-class gesture demo on the local webcam.

Framing, not the model, is what decides whether this works. The training data is
square, so the demo takes the centre square of the frame before resizing: the
network was trained on square crops that fill its canvas, and handing it a whole
16:9 camera frame presents a geometry it has never seen. Measured on a real 720p
thumbs-up capture under the older 16:9 geometry: the same hand, at an identical
112 px in the network input, scored `other` 0.998 in the full frame and
`finger_up` 0.894 in a square crop. Press `c` to turn the crop off and watch the
same hand fall back; that A/B is the point.

The demo reuses the training preprocessing contract
(`src.preprocess.preprocess_image`) and the geometry of the checkpoint's own
model config, so the resize, padding colour and normalisation are the ones the
board will apply, at the size those weights were trained for. The inset shows
exactly the tensor the network reads.

The decision comes from `src.decision.decide` driven by
`configs/<model_id>_decision.json`, the same rule an offline report would use, so
what is demonstrated is what can be measured. That rule is still the uncalibrated
placeholder: it is a knob, not an acceptance result.

`s` writes the whole frame plus the scores and the crop box into a session
directory, which is the raw material for the same-domain evaluation set the
training strategy asks for.

CUDA is required and there is no CPU fallback.

Run from the repository root:
  python gesture/tools/webcam_demo.py
  python gesture/tools/webcam_demo.py --camera 1
  python gesture/tools/webcam_demo.py --image gesture/dataset/手掌/palm/<f>.jpeg

Keys:
  q / ESC   quit
  space     pause / resume
  i         toggle the model-input inset
  c         toggle the centre-square crop (`square` <-> `full`)
  s         save a snapshot (frame + scores) into the session directory
  [ , ;     lower a threshold by 0.05
  ] . '     raise a threshold by 0.05
            (a single-number rule has one knob, so every key moves it)
  - =       hold frames -/+
"""
import argparse
import copy
import json
import sys
import time
from datetime import datetime
from pathlib import Path

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))

OTHER = 3
BAR_COLOURS = {'fist': (80, 90, 230), 'finger_up': (90, 190, 90),
               'thumb_down': (200, 140, 60), 'other': (140, 140, 140)}


def open_camera(cv2, index):
    for backend in (cv2.CAP_DSHOW, cv2.CAP_ANY):
        capture = cv2.VideoCapture(index, backend)
        if capture.isOpened():
            capture.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            capture.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
            return capture, backend
        capture.release()
    raise SystemExit(f'cannot open camera index {index}')


def centre_square_box(shape):
    """Centred square using the frame's shorter side."""
    height, width = shape[:2]
    side = min(height, width)
    left, top = (width - side) // 2, (height - side) // 2
    return left, top, left + side, top + side


def model_region(frame, crop_mode):
    """Return the region handed to `preprocess_image`, and its box in `frame`.

    `square` crops the centre square, which is what the network was trained on:
    square crops that fill the canvas. `full` passes the whole frame, reproducing
    the framing that was measured to break. The box is returned in original-frame
    coordinates so a saved snapshot can be re-cropped later without guessing.
    """
    if crop_mode != 'square':
        return frame, None
    left, top, right, bottom = centre_square_box(frame.shape)
    return frame[top:bottom, left:right], (left, top, right, bottom)


def nudge(rule, class_name, delta):
    """Adjust a threshold in place; returns the (possibly replaced) rule.

    A single-number rule has one knob, so every threshold key moves it.
    """
    if isinstance(rule, (int, float)) and not isinstance(rule, bool):
        return round(min(0.95, max(0.0, rule + delta)), 2)
    if not isinstance(rule, dict):
        return rule
    for step in rule['cascade']:
        if step['class'] == class_name and 'min_score' in step:
            step['min_score'] = round(min(0.95, max(0.0,
                                                    step['min_score'] + delta)), 2)
            break
    return rule


def thresholds(rule):
    if isinstance(rule, (int, float)) and not isinstance(rule, bool):
        return f'single threshold {rule:.2f}'
    if not isinstance(rule, dict):
        return 'argmax, no threshold'
    return '  '.join(f"{s['class']}={s['min_score']:.2f}"
                     for s in rule['cascade'] if 'min_score' in s)


def draw_bars(cv2, frame, probabilities, keys, x, y, width=210, row=26):
    for i, key in enumerate(keys):
        value = float(probabilities[i])
        top = y + i * row
        cv2.rectangle(frame, (x, top), (x + width, top + 15), (40, 40, 40), -1)
        cv2.rectangle(frame, (x, top), (x + int(width * value), top + 15),
                      BAR_COLOURS.get(key, (200, 200, 200)), -1)
        cv2.putText(frame, f'{key:<12s} {value:5.3f}', (x, top + 13),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (235, 235, 235), 1, cv2.LINE_AA)


def draw_inset(cv2, frame, array):
    """Show the model input at native size so nothing is hidden.

    The size comes from the tensor, not from a constant: it is the checkpoint's
    geometry, and this overlay is how the operator sees what the network sees.
    """
    height, width = array.shape[1], array.shape[2]
    inset = ((array.transpose(1, 2, 0) * 128.0) + 128.0)
    inset = inset.round().clip(0, 255).astype('uint8')
    inset = cv2.cvtColor(inset, cv2.COLOR_RGB2BGR)
    inset = cv2.resize(inset, (width, height), interpolation=cv2.INTER_NEAREST)
    y0 = frame.shape[0] - height - 30
    frame[y0:y0 + height, 0:width] = inset
    cv2.rectangle(frame, (0, y0), (width - 1, y0 + height - 1), (90, 90, 90), 1)
    cv2.putText(frame, f'model input {width}x{height}', (4, y0 - 6),
                cv2.FONT_HERSHEY_SIMPLEX, 0.45, (180, 180, 180), 1)
    return width


def draw_crop_guide(cv2, frame, box, crop_mode):
    """Dim everything outside the crop so the framing convention is visible."""
    if box is None:
        cv2.putText(frame, f'crop: {crop_mode} (no crop - the broken framing)',
                    (12, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (90, 160, 255), 1,
                    cv2.LINE_AA)
        return
    left, top, right, bottom = box
    kept = frame[top:bottom, left:right].copy()
    frame[:] = cv2.convertScaleAbs(frame, alpha=0.45)
    frame[top:bottom, left:right] = kept
    cv2.rectangle(frame, (left, top), (right - 1, bottom - 1), (120, 220, 120), 2)
    cv2.putText(frame, 'hand here', (left + 10, top + 68),
                cv2.FONT_HERSHEY_SIMPLEX, 0.65, (120, 220, 120), 2, cv2.LINE_AA)


def annotate(cv2, decide, explain, frame, array, probabilities, keys, rule, hold,
             streak, fps, show_inset, box=None, crop_mode='square'):
    display = frame.copy()
    height, width = display.shape[:2]
    draw_crop_guide(cv2, display, box, crop_mode)
    predicted = int(decide(probabilities, rule, keys))
    accept = predicted != OTHER and streak >= hold
    colour = (60, 220, 60) if accept else (200, 200, 200)
    label = keys[predicted] if accept else f'{keys[predicted]} (idle)'

    cv2.rectangle(display, (0, 0), (width, 46), (25, 25, 25), -1)
    cv2.putText(display, label, (12, 33), cv2.FONT_HERSHEY_SIMPLEX, 1.0,
                colour, 2, cv2.LINE_AA)
    draw_bars(cv2, display, probabilities, keys, width - 232, 60)
    inset_width = draw_inset(cv2, display, array) if (show_inset and array is not None) else 0
    # Keep the status lines clear of the inset in the bottom-left corner.
    text_x = inset_width + 10 if inset_width else 12
    cv2.putText(display, f'{fps:4.1f} fps   {explain(probabilities, rule, keys)}',
                (text_x, height - 30), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                (200, 230, 200), 1, cv2.LINE_AA)
    cv2.putText(display, f'{thresholds(rule)}   streak {streak} (need {hold})',
                (text_x, height - 12), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                (220, 220, 220), 1, cv2.LINE_AA)
    cv2.putText(display, 'FIRE' if accept else 'idle', (width - 232, 40),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, colour, 2, cv2.LINE_AA)
    return display, predicted, accept


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path,
                        default=GESTURE / 'models/g4net_v4_trained/best_deploy.pt')
    parser.add_argument('--rule', type=Path,
                        help='decision rule document; defaults to '
                             'configs/<model_id>_decision.json for the checkpoint')
    parser.add_argument('--camera', type=int, default=0)
    parser.add_argument('--image', type=Path,
                        help='run once on a still image instead of the camera')
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--crop', default='square', choices=['square', 'full'],
                        help='`square` crops the centre square before the '
                             'letterbox, matching the training framing; `full` '
                             'feeds the whole frame (the framing that was '
                             'measured to fail)')
    parser.add_argument('--hold', type=int, default=1,
                        help='consecutive frames the class must stay predicted')
    parser.add_argument('--session', default=None,
                        help='snapshot directory name (default: a timestamp)')
    args = parser.parse_args()

    import numpy as np
    import torch

    if not args.device.startswith('cuda'):
        raise SystemExit('an explicit CUDA device is required, e.g. --device cuda:0')
    if not torch.cuda.is_available():
        raise SystemExit('CUDA unavailable; CPU fallback is forbidden.')
    device = torch.device(args.device)
    if device.index is None or device.index >= torch.cuda.device_count():
        raise SystemExit(f'bad device index: {args.device}')

    import cv2
    from PIL import Image
    from src.decision import decide, describe, explain, load_rule
    from src.preprocess import preprocess_image
    from src.spec import CURRENT_MODEL, load_config, model_config_for
    from src.train import load_model_from_checkpoint

    print(f'torch {torch.__version__}  device {device}  '
          f'{torch.cuda.get_device_name(device)}')
    model, step, metrics, run_config = load_model_from_checkpoint(
        args.checkpoint, device)
    model.eval()
    keys = list(model.class_keys)
    # The geometry belongs to the checkpoint, not to this script: resolve it from
    # the checkpoint's own model_id so running an older one still preprocesses
    # the way those weights were trained.
    model_config_path = model_config_for((run_config or {}).get('model_id',
                                                               CURRENT_MODEL))
    geometry_spec = load_config(model_config_path)
    print(f'checkpoint {args.checkpoint.name} step {step}')
    print(f'  model {model_config_path.name}  input '
          f"{geometry_spec['input']['width']}x{geometry_spec['input']['height']}  "
          f'classes {keys}')
    if metrics:
        print(f"  val macro-F1 {metrics['macro_f1']:.4f}  "
              f"worst target recall {metrics['worst_target_recall']:.4f}  "
              f"other FPR {metrics['target_false_positive_rate']['any_target']:.4f}")

    model_id = (run_config or {}).get('model_id', 'g4net_v2')
    rule_path = args.rule or GESTURE / 'configs' / f'{model_id}_decision.json'
    if rule_path.is_file():
        rule = copy.deepcopy(load_rule(rule_path))
        print(f'rule {rule_path.name}: {describe(rule, keys)}')
    else:
        rule = None
        print(f'no rule file at {rule_path}; using argmax')

    if args.image is not None:
        # cv2.imread uses the Windows ANSI codepage and fails on non-ASCII
        # paths, which every dataset path here is. Decode the bytes instead.
        buffer = np.fromfile(args.image, dtype='uint8')
        frame = cv2.imdecode(buffer, cv2.IMREAD_COLOR)
        if frame is None:
            raise SystemExit(f'cannot read {args.image}')
        region, box = model_region(frame, args.crop)
        array, geometry = preprocess_image(
            Image.fromarray(cv2.cvtColor(region, cv2.COLOR_BGR2RGB)),
            model_config_path)
        tensor = torch.from_numpy(array).unsqueeze(0).to(device)
        with torch.inference_mode():
            probabilities = model(tensor).softmax(dim=1)[0].cpu().numpy()
        display, predicted, accept = annotate(
            cv2, decide, explain, frame, array, probabilities, keys, rule, 1, 1,
            0.0, True, box, args.crop)
        print(f'  crop {args.crop}  box {box}  content '
              f'{geometry["resized_wh"][0]}x{geometry["resized_wh"][1]} '
              f'pad {geometry["pad_left_top"]}')
        print('  scores: ' + '  '.join(
            f'{k}={v:.4f}' for k, v in zip(keys, probabilities)))
        print(f'  argmax {keys[int(probabilities.argmax())]}   '
              f'{explain(probabilities, rule, keys)}   accept {accept}')
        out = Path('webcam_demo_still.png')
        cv2.imwrite(str(out), display)
        print(f'  wrote {out}')
        return

    session = args.session or datetime.now().strftime('%Y%m%d_%H%M%S')
    session_dir = GESTURE / 'camera_sessions' / session
    session_dir.mkdir(parents=True, exist_ok=True)
    scores_path = session_dir / 'predictions.jsonl'
    print(f'snapshots -> {session_dir}')

    capture, backend = open_camera(cv2, args.camera)
    print(f'camera {args.camera} opened (backend {backend})')

    hold = args.hold
    crop_mode = args.crop
    show_inset, paused = True, False
    streak_key, streak = None, 0
    frames, saved, started, fps = 0, 0, time.time(), 0.0
    frame = array = None
    box = geometry = None
    probabilities = np.zeros(len(keys), dtype='float32')

    try:
        while True:
            if not paused:
                ok, frame = capture.read()
                if not ok:
                    print('camera read failed')
                    break
                region, box = model_region(frame, crop_mode)
                array, geometry = preprocess_image(
                    Image.fromarray(cv2.cvtColor(region, cv2.COLOR_BGR2RGB)),
                    model_config_path)
                tensor = torch.from_numpy(array).unsqueeze(0).to(device)
                with torch.inference_mode():
                    probabilities = model(tensor).softmax(dim=1)[0].cpu().numpy()
                if frames == 0:
                    print(f'frame {frame.shape[1]}x{frame.shape[0]}  '
                          f'crop {crop_mode} box {box}  content '
                          f'{geometry["resized_wh"][0]}x{geometry["resized_wh"][1]}'
                          f' pad {geometry["pad_left_top"]}')
                top_key = keys[int(decide(probabilities, rule, keys))]
                if top_key == streak_key:
                    streak += 1
                else:
                    streak_key, streak = top_key, 1
                frames += 1
                if frames % 15 == 0:
                    now = time.time()
                    fps = 15 / max(now - started, 1e-9)
                    started = now

            display, predicted, accept = annotate(
                cv2, decide, explain, frame, array, probabilities, keys, rule,
                hold, streak, fps, show_inset, box, crop_mode)
            cv2.imshow(f'G4Net v2 gesture demo   crop={crop_mode}', display)

            key = cv2.waitKey(1) & 0xFF
            if key in (ord('q'), 27):
                break
            if key == ord(' '):
                paused = not paused
            elif key == ord('i'):
                show_inset = not show_inset
            elif key == ord('c'):
                crop_mode = 'full' if crop_mode == 'square' else 'square'
                print(f'  crop -> {crop_mode}')
            elif key in (ord('['), ord(']'), ord(','), ord('.'), ord(';'),
                         ord("'")):
                delta = -0.05 if key in (ord('['), ord(','), ord(';')) else 0.05
                name = {ord('['): 'fist', ord(']'): 'fist',
                        ord(','): 'finger_up', ord('.'): 'finger_up',
                        ord(';'): 'thumb_down', ord("'"): 'thumb_down'}[key]
                rule = nudge(rule, name, delta)
                print(f'  threshold -> {thresholds(rule)}')
            elif key == ord('-'):
                hold = max(1, hold - 1)
                print(f'  hold -> {hold}')
            elif key == ord('='):
                hold = min(30, hold + 1)
                print(f'  hold -> {hold}')
            elif key == ord('s'):
                stamp = f'{saved:04d}'
                cv2.imwrite(str(session_dir / f'frame_{stamp}.jpg'), frame)
                with scores_path.open('a', encoding='utf-8') as handle:
                    handle.write(json.dumps(dict(
                        frame=f'frame_{stamp}.jpg',
                        session=session,
                        crop=crop_mode,
                        crop_box=list(box) if box else None,
                        model_input_geometry=geometry,
                        model_config=model_config_path.name,
                        predicted=keys[predicted],
                        argmax=keys[int(probabilities.argmax())],
                        reason=explain(probabilities, rule, keys),
                        rule=rule,
                        streak=streak,
                        accepted=bool(accept),
                        hold_setting=hold,
                        scores={k: round(float(v), 5)
                                for k, v in zip(keys, probabilities)},
                    ), ensure_ascii=False) + '\n')
                saved += 1
                print(f'  saved {saved}: pred={keys[predicted]}  '
                      f'{explain(probabilities, rule, keys)}')
    finally:
        capture.release()
        cv2.destroyAllWindows()

    print('\nfinal rule: ' + json.dumps(rule, ensure_ascii=False))
    print(f'session {session}: {saved} snapshot(s) in {session_dir}')
    if saved:
        print(f'scores in {scores_path}')


if __name__ == '__main__':
    main()
