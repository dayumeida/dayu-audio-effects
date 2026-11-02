import subprocess, json, time, hashlib
from pathlib import Path
start=time.monotonic()
results=[]
for strength in [0,40,80,100]:
 for target in [-24,-12,0]:
  record={'strength':strength,'target':target}
  for name,exe,extra in [('original','/tmp/dayu-levelmatic-reference-probe',['--render']),('reconstruction','/tmp/dayu-leveler-reference-tests',[])]:
   args=[exe]+extra+['--strength',str(strength),'--target',str(target)]
   t=time.monotonic()
   try:
    r=subprocess.run(args,capture_output=True,text=True,timeout=30)
    try:d=json.loads(r.stdout)
    except Exception:d={'rawStdout':r.stdout}
    d.update(exitCode=r.returncode,wallSeconds=time.monotonic()-t,stderr=r.stderr)
   except subprocess.TimeoutExpired as e:
    d={'error':'30 second timeout','wallSeconds':time.monotonic()-t}
   record[name]=d
  original=record['original']; candidate=record['reconstruction']
  if 'outputPerSecond' in original and 'outputPerSecond' in candidate:
   record['comparison']=[{'second':a['second'],'rmsErrorDB':b['rmsDB']-a['rmsDB'],'peakErrorDB':b['peakDB']-a['peakDB']} for a,b in zip(original['outputPerSecond'],candidate['outputPerSecond'])]
   record['maxAbsoluteRMSErrorDB']=max(abs(x['rmsErrorDB']) for x in record['comparison'])
   record['maxAbsolutePeakErrorDB']=max(abs(x['peakErrorDB']) for x in record['comparison'])
  print({k:v for k,v in record.items() if k not in ['original','reconstruction','comparison']},flush=True)
  results.append(record)
p=Path('Analysis/Levelmatic/parameter-matrix.json')
summary={'coreSHA256':hashlib.sha256(Path('大鱼音频效果器Extension/DSP/LevelerCore.hpp').read_bytes()).hexdigest(),'wallSeconds':time.monotonic()-start,'compileFlags':'-std=c++17 -O2 -ffp-contract=off','limitations':'Original installed AUv2 is trial; watermark or license state can affect original output. No authorization bypass. Per-second metrics do not prove arbitrary-input bit-exact equivalence. Each child process timeout 30 seconds.','cases':results}
p.write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print('saved',p,'wall',summary['wallSeconds'],flush=True)
