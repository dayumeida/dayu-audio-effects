from pathlib import Path
import numpy as np,json,math
root=Path(__file__).parent
rows=[]
for jpath in sorted(root.glob('reference-*.json')):
 try:
  j=json.loads(jpath.read_text());base=jpath.name.replace('reference-','');k=json.loads((root/('native-'+base)).read_text());rate=int(j['rate'])
  da=math.ceil(j['latencySeconds']*rate-1.e-6);db=round(k['latencySeconds']*rate)
  a=np.fromfile(jpath.with_suffix('.f32'),np.float32)[da:];b=np.fromfile((root/('native-'+base)).with_suffix('.f32'),np.float32)[db:]
  n=min(len(a),len(b));x=a[rate:n];y=b[rate:n];d=x-y
  rows.append({'rate':rate,'strength':j['strength'],'low':j['low'],'startSourceFrame':rate,'endSourceFrame':n,'referenceDelayFrames':da,'nativeFixedDelayFrames':db,'RMSerror':float(np.sqrt(np.mean(d*d))),'maxError':float(np.max(abs(d))),'correlation':float(np.corrcoef(x,y)[0,1])})
 except (ValueError,FileNotFoundError,KeyError):pass
(root/'whole-chain-comparison.json').write_text(json.dumps({'description':'8-second deterministic harmonics plus noise; original trial AU, real-time-paced renders. Alignment removes ceil(reported reference latency) and exact native latency. First source second excluded because startup padding intentionally differs. Mono. No arbitrary-input bit-exact claim.','cases':rows},indent=2))
print(json.dumps(rows,indent=2))
