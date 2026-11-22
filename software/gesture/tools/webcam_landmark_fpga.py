"""Live hand_landmark_lite demo using the FPGA integer datapath contract.

This is a CUDA software emulator of the packed Ti60 integer arithmetic; it does
not communicate with or execute on a Ti60 board. It reuses the current
poll/acquire/track camera UI so its crop geometry and display are directly
comparable with webcam_landmark_poll.py.

Run from the repository root after clearing Efinity's Python variables:
  python software/gesture/tools/webcam_landmark_fpga.py --camera 0
  python software/gesture/tools/webcam_landmark_fpga.py --source webcam_demo_still.png

Keys: q/ESC quit, s save a frame, r restart the scan.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(REPO / "hardware/network_board/tools/gesture_model"))

from webcam_landmark_poll import main  # noqa: E402
from torch_fpga_reference import FpgaIntegerCuda  # noqa: E402


class FpgaCameraModel:
    """Adapter matching webcam_landmark_poll.LiteLandmark's inference API."""

    backend_name = "FPGA integer contract emulated on CUDA"

    def __init__(self, _unused_model_path=None, input_size=224):
        import cv2
        import numpy as np
        from time import perf_counter

        self._np = np
        self._cv2 = cv2
        self._perf_counter = perf_counter
        self.input_size = float(input_size)
        self.rotate = False
        print("正在预热 FPGA 整数路径 CUDA 仿真器…", flush=True)
        self._impl = FpgaIntegerCuda(device="cuda:0")
        print(f"FPGA integer emulator: CUDA device 0, {self._impl.gpu_name}; "
              "no CPU fallback; not connected to physical FPGA", flush=True)
        self.last_ms = 0.0

    @staticmethod
    def palm_from_landmarks(pts):
        from webcam_landmark_poll import LiteLandmark
        return LiteLandmark.palm_from_landmarks(pts)

    def _run(self, tile_bgr):
        cv = self._cv2
        tile = cv.resize(tile_bgr, (int(self.input_size), int(self.input_size)),
                         interpolation=cv.INTER_AREA)
        rgb = cv.cvtColor(tile, cv.COLOR_BGR2RGB).astype(self._np.float32) / 255.0
        start = self._perf_counter()
        out = self._impl.infer(rgb)
        # Synchronization is included in latency so the on-screen number is real.
        import torch
        torch.cuda.synchronize(self._impl.device)
        self.last_ms = (self._perf_counter() - start) * 1e3
        raw = out["Identity"].reshape(-1, 3)[:, :2].astype(self._np.float64)
        conf = float(out["Identity_1"].reshape(-1)[0])
        handed = float(out["Identity_2"].reshape(-1)[0])
        return raw, conf, handed

    def infer_window(self, image, box):
        from webcam_landmark_poll import LiteLandmark
        return LiteLandmark.infer_window(self, image, box)

    def infer_tracked(self, image, palm_pts, palm_box):
        from webcam_landmark_poll import LiteLandmark
        return LiteLandmark.infer_tracked(self, image, palm_pts, palm_box)

    @staticmethod
    def _crop_pad(*args, **kwargs):
        from webcam_landmark_poll import LiteLandmark
        return LiteLandmark._crop_pad(*args, **kwargs)

    def _map_back(self, *args, **kwargs):
        from webcam_landmark_poll import LiteLandmark
        return LiteLandmark._map_back(self, *args, **kwargs)


if __name__ == "__main__":
    main(model_class=FpgaCameraModel,
         description="hand_landmark_lite FPGA integer-path camera demo (CUDA emulator)")
