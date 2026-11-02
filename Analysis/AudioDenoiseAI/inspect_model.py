from pathlib import Path
import struct,json,collections
ROOT=Path(__file__).parent
def varint(b,i):
 v=0;s=0
 while True:
  c=b[i];i+=1;v|=(c&127)<<s
  if c<128:return v,i
  s+=7
def pb(b):
 i=0;d=collections.defaultdict(list)
 while i<len(b):
  t,i=varint(b,i);n=t>>3;w=t&7
  if w==0:v,i=varint(b,i)
  elif w==2:l,i=varint(b,i);v=b[i:i+l];i+=l
  elif w==5:v=b[i:i+4];i+=4
  elif w==1:v=b[i:i+8];i+=8
  else:raise ValueError((i,w))
  d[n].append(v)
 return d
def txt(v):return v.decode('utf8')
def first(d,n,default=None):return d.get(n,[default])[0]
def ten(b):
 d=pb(b);dims=[]
 for x in d.get(1,[]):
  if isinstance(x,int):dims.append(x)
  else:
   i=0
   while i<len(x):v,i=varint(x,i);dims.append(v)
 floats=[]
 for x in d.get(4,[]):floats.extend(struct.unpack('<'+'f'*(len(x)//4),x))
 raw=first(d,9,b'')
 if raw and first(d,2)==1:floats=list(struct.unpack('<'+'f'*(len(raw)//4),raw))
 return {'name':txt(first(d,8,b'')),'dims':dims,'type':first(d,2),'floats':floats}
def val(b):
 d=pb(b); t=pb(first(d,2,b'')); t=pb(first(t,1,b'')); shape=pb(first(t,2,b''));dims=[]
 for x in shape.get(1,[]):
  z=pb(x);dims.append(first(z,1,txt(first(z,2,b''))))
 return {'name':txt(first(d,1,b'')),'dims':dims,'type':first(t,1)}
m=pb((ROOT/'model.onnx').read_bytes());g=pb(first(m,7));nodes=[];weights={}
for raw in g.get(1,[]):
 d=pb(raw);attrs={}
 for a in d.get(5,[]):
  ad=pb(a);name=txt(first(ad,1,b''));
  if 5 in ad:
   t=ten(ad[5][0]);key=txt(first(d,2,b''));weights[key]=t; attrs[name]={k:v for k,v in t.items() if k!='floats'}
  elif 8 in ad:attrs[name]=ad[8]
  elif 7 in ad:attrs[name]=[struct.unpack('<f',x)[0] for x in ad[7]]
  elif 3 in ad:attrs[name]=ad[3]
  elif 2 in ad:attrs[name]=struct.unpack('<f',ad[2][0])[0]
  elif 4 in ad:attrs[name]=txt(ad[4][0])
 nodes.append({'in':list(map(txt,d.get(1,[]))),'out':list(map(txt,d.get(2,[]))),'name':txt(first(d,3,b'')),'op':txt(first(d,4,b'')),'attrs':attrs})
r={'input':list(map(val,g.get(11,[]))),'output':list(map(val,g.get(12,[]))),'ops':dict(collections.Counter(x['op'] for x in nodes)),'nodes':nodes,'weightCount':sum(len(t['floats']) for t in weights.values())}
(ROOT/'model-graph.json').write_text(json.dumps(r,indent=2))
print(json.dumps({k:v for k,v in r.items() if k!='nodes'},indent=2))
for n in nodes:
 print(n['op'],','.join(n['in']),'=>',','.join(n['out']),str(n['attrs']))
