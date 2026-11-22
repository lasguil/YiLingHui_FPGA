from pathlib import Path
import sys,json
import numpy as np

PROJECT=Path(__file__).resolve().parents[1]
ROOT=PROJECT.parents[1]
HANDOFF=ROOT/'gesture/try_easy_gesture/handoff'
sys.path.insert(0,str(HANDOFF.parent))
from wave_detector import WaveDetector

def write_case(path,frames):
 detector=WaveDetector();events=[]
 with path.open('w',encoding='ascii') as f:
  for i,blocks in enumerate(frames):
   event=detector.step(blocks)
   s=detector.last_state
   stats=[-1]*4 if s is None else [s['area'],s['fill'],s['threshold'],s['centroid_q3'] if s['centroid_q3'] is not None else -1]
   expected=[0 if event is None else (2 if event=='RIGHT' else 1),*stats,
     int(detector.active),int(detector.blocked),detector.cx_ref,detector.peak_area,
     detector.peak_fill,min(detector.frames_in_episode,31),min(detector.gap,3),detector.refract]
   f.write(' '.join(map(str,[*map(int,blocks.flat),*expected]))+'\n')
   if event:events.append([i,event])
 return {'frames':len(frames),'events':events}

def main():
 out=PROJECT/'tmp/wave8x8';out.mkdir(parents=True,exist_ok=True)
 result={}
 for source in sorted((HANDOFF/'golden').glob('*_blocks.txt')):
  rows=[]
  for line in source.read_text().splitlines():
   if not line.strip() or line.startswith('#'):continue
   rows.append(np.array(list(map(int,line.split())),dtype=np.int16).reshape(8,8))
  result[source.stem]=write_case(out/(source.stem+'.txt'),rows)
 rng=np.random.default_rng(20261112)
 frames=[];base=rng.integers(8,30,(8,8),dtype=np.int16)
 for step in (1,4,1):
  for direction in (range(8),range(7,-1,-1)):
   frames += [base.copy() for _ in range(4)]
   for column in direction:
    frame=base.copy();frame[:,column]=60
    frames += [frame.copy() for _ in range(step)]
 frames += [np.zeros((8,8),dtype=np.int16),np.full((8,8),63,dtype=np.int16)]*8
 frames += [rng.integers(0,64,(8,8),dtype=np.int16) for _ in range(300)]
 result['integer_edges']=write_case(out/'integer_edges.txt',frames)
 (out/'vectors.json').write_text(json.dumps(result,indent=2)+'\n')
 print('Generated',sum(r['frames'] for r in result.values()),'frame-by-frame arithmetic and FSM vectors.')

if __name__=='__main__':main()
