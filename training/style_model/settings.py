"""NativeGroupMixNet-v1 FP32, main-256, single-style experiment."""
import hashlib,json
from pathlib import Path

HERE=Path(__file__).resolve().parent
METHOD=HERE.parent
STUDENTS=METHOD.parent
PREP=HERE
DATASET=Path('/data1/fpga_style_transfer_2026_tmp/datasets/main_256')
INDEX=DATASET/'manifest.jsonl'
STYLE=DATASET.parent/'vangogh_styles/vangogh_00.jpg'
VGG19=METHOD/'quarter_vgg_local_20260904/vgg19_imagenet_features.pt'
RUN_ROOT=STUDENTS/'runs/native_groupmix_main256_20260910_20k'
# v2 candidates from docs/NativeGroupMixNet_v2_three_models_NPU_quantization_guide.md.
# They share every training hyper-parameter with native_groupmix_v1 - same
# teacher, data, augmentation, loss, optimizer, schedule, batch size and step
# count - so that only the generator topology differs between the three.
V2_RUNS={
    'v2a_depthcut': STUDENTS/'runs/v2a_depthcut_20260921',
    'v2b_groupcut': STUDENTS/'runs/v2b_groupcut_20260921',
    'v2c_spatialshift': STUDENTS/'runs/v2c_spatialshift_20260921',
}
# V2-D/V2-E from docs/NativeGroupMixNet_v2_no_depth_cut_two_models_D_E_guide.md.
# Guide section 17 freezes the experiment names; the run directories use them
# verbatim.  Same recipe as every other v2 run: only the topology changes.
V2DE_RUNS={
    'native_groupmix_v2d_narrowdeep_c16_fp32':
        STUDENTS/'runs/native_groupmix_v2d_narrowdeep_c16_fp32',
    'native_groupmix_v2e_factorizedshuffle_c32_fp32':
        STUDENTS/'runs/native_groupmix_v2e_factorizedshuffle_c32_fp32',
}
EXPERIMENTS=('native_groupmix_v1',)+tuple(V2_RUNS)+tuple(V2DE_RUNS)
SAMPLE_BUDGET=80000

def run_root(name):
    if name=='native_groupmix_v1':return RUN_ROOT
    if name in V2DE_RUNS:return V2DE_RUNS[name]
    return V2_RUNS[name]

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def batch_size(name):
    assert name in EXPERIMENTS
    return 4
def learning_rate(samples_before,budget):
    return .0002*max(0.,1.-max(0.,samples_before-budget/2)/(budget/2))
def readiness():
    assert INDEX.is_file()
    assert VGG19.is_file()
    assert STYLE.is_file()
    assert (DATASET/'images').is_dir()
    rows=[json.loads(line) for line in INDEX.read_text(encoding='utf-8').splitlines() if line.strip()]
    assert len(rows)==53449
    assert rows[0]['size']==[256,256] and rows[-1]['id']=='053449'
    return True
