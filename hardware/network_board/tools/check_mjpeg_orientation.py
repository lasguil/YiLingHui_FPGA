"""Detect the observed 8x8 block reversal against a static HDMI reference.

The reference must contain the same desktop without motion. This supplements
visual review; it does not measure general JPEG quality or dynamic content.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('jpeg', type=Path)
ap.add_argument('hdmi_reference', type=Path)
ap.add_argument('--out', type=Path)
args = ap.parse_args()
with Image.open(args.jpeg) as im:
    received = np.asarray(im.convert('YCbCr'))[:, :, 0].astype(float)
with Image.open(args.hdmi_reference) as im:
    reference = np.asarray(im.convert('YCbCr'))[:, :, 0].astype(float)
height, width = reference.shape
reference = reference[np.arange(height) % 3 != 2, :][:, np.arange(width) % 3 != 2]
if received.shape != reference.shape or any(n % 8 for n in received.shape):
    raise SystemExit('Expected matching 2/3 sampled dimensions divisible by 8')
height, width = received.shape
basis = np.cos((2*np.arange(8)[None, :]+1)*np.arange(8)[:, None]*np.pi/16)*0.5
basis[0] /= np.sqrt(2)

def coefficients(pixels):
    blocks = pixels.reshape(height//8, 8, width//8, 8).transpose(0, 2, 1, 3)
    return np.einsum('ij,...jk,lk->...il', basis, blocks, basis).reshape(-1, 64)

expected, actual = coefficients(reference), coefficients(received)
expected -= expected.mean(axis=0)
actual -= actual.mean(axis=0)
denominator = np.linalg.norm(expected, axis=0)*np.linalg.norm(actual, axis=0)
correlation = np.divide((expected*actual).sum(axis=0), denominator,
                        out=np.zeros(64), where=denominator > 0)
# Horizontal/vertical first and second AC terms distinguish reversal from a
# general level/colour difference between the HDMI card and FPGA JPEG capture.
probes = (1, 2, 8, 16)
result = dict(jpeg=str(args.jpeg), reference=str(args.hdmi_reference),
              size=[width, height],
              ac_correlations={str(i): float(correlation[i]) for i in probes},
              pass_orientation=bool(all(correlation[i] > 0.90 for i in probes)))
text = json.dumps(result, indent=2)+'\n'
if args.out:
    args.out.write_text(text)
print(text, end='')
raise SystemExit(0 if result['pass_orientation'] else 1)
