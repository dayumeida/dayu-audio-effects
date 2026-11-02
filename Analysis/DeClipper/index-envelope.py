from pathlib import Path
import struct,re,json
r=Path(__file__).parent;b=(r/'era5-arm64.bin').read_bytes();n=struct.unpack_from('<I',b,16)[0];p=32;starts=[]
for _ in range(n):
 c,z=struct.unpack_from('<II',b,p)
 if c==0x26:
  off,size=struct.unpack_from('<II',b,p+8);a=0;x=0;s=0
  for v in b[off:off+size]:
   x|=(v&127)<<s
   if v&128:s+=7
   else:
    if not x:break
    a+=x;starts.append(a);s=0;x=0
 p+=z
lines=(r/'era5-arm64-disassembly.txt').read_text().splitlines();funcs=[]; idx=0;current=None
for l in lines:
 m=re.match(r'\s*([0-9a-f]+):',l)
 if not m:continue
 a=int(m[1],16)
 while idx<len(starts) and starts[idx]<=a:
  if current:funcs.append(current)
  current={'address':starts[idx],'lines':[]};idx+=1
 if current:current['lines'].append(l)
if current:funcs.append(current)
for f in funcs:
 f['calls']=sorted(set(int(x,16) for l in f['lines'] for x in re.findall(r'\tbl\t0x([0-9a-f]+)',l)))
 f['length']=len(f['lines'])
(r/'function-index.json').write_text(json.dumps([{k:v for k,v in f.items() if k!='lines'} for f in funcs],indent=2))
for f in funcs:
 if 0x6a000<=f['address']<=0x6a640:
  print(hex(f['address']), f['length'], ' '.join(hex(x) for x in f['calls']))
  (r/f'func-{f["address"]:x}.asm').write_text('\n'.join(f['lines'])+'\n')
