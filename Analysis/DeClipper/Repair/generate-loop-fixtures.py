from pathlib import Path
import json,struct,sys
r=Path(__file__).parent
for name in sys.argv[1:] or ['standard']:
 j=json.loads((r/('loop-runtime-'+name+'.json')).read_text())
 with (r/('loop-fixture-'+name+'.bin')).open('wb') as f:
  for d in j:
   for ch,c in enumerate(d['ch']):
    f.write(struct.pack('<9i',d['n'],len(c['regions']),ch,d['lpContext'],d['splineContext'],d['processLimit'],c['order'],d['quality'],len(c['polyBefore'])))
    for a in [c['input'],c['output'],c['polyBefore'],c['polyAfter']]:f.write(struct.pack('<%dd'%len(a),*a))
    for a in [c['regions'],c['regionsAfter']]:
     for v in a:f.write(struct.pack('<3i',*v))
