import lldb,json,struct,os
from pathlib import Path
root=Path('/Volumes/DayuMedia 4TB/大鱼音频插件开发/大鱼音频效果器/Analysis/DeClipper/Repair')
tag=os.getenv('DAYU_CAPTURE_TAG','standard')
limit=int(os.getenv('DAYU_CAPTURE_LIMIT','24'))
s={'calls':[],'pending':None,'bps':{},'total':0}
def read(p,a,n):
 assert 0<=n<10000000
 e=lldb.SBError();b=p.ReadMemory(a,n,e)
 if not e.Success():raise RuntimeError(str(e))
 return b
def q(p,a):return struct.unpack('<Q',read(p,a,8))[0]
def i(p,a):return struct.unpack('<i',read(p,a,4))[0]
def ds(p,a,n):return list(struct.unpack('<%dd'%n,read(p,a,n*8))) if n else []
def init(debugger,command,result,internal_dict):
 t=debugger.GetSelectedTarget();base=t.FindModule(lldb.SBFileSpec('ERA5_DeClipperFxFactory')).FindSection('__TEXT').GetLoadAddress(t)
 for addr,fn in [(0x2bf60,'entry'),(0x2d858,'end')]:
  bp=t.BreakpointCreateByAddress(base+addr);bp.SetScriptCallbackFunction('lldb_loop.'+fn);s['bps'][fn]=bp
def entry(f,bp,_):
 p=f.GetThread().GetProcess();obj=f.FindRegister('x0').GetValueAsUnsigned();s['total']+=1
 if len(s['calls'])>=limit:return False
 ch=i(p,obj+0x2b0);n=q(p,obj+0x258);ptr=q(p,obj+0x250);counts=[i(p,q(p,obj+0x2c8)+4*c) for c in range(ch)]
 if not any(counts):return False
 item={'call':s['total'],'n':n,'channels':ch,'lpContext':i(p,obj+0x2b4),'processLimit':i(p,obj+0x2b8),'splineContext':i(p,obj+0x2c0),'mergeLimit':i(p,obj+0x2e0),'quality':i(p,obj+0x2ec),'ch':[]}
 for c in range(ch):
  reg=q(p,q(p,obj+0x2f0)+c*24);lpc=q(p,obj+0x178)+c*0x88
  item['ch'].append({'input':ds(p,ptr+c*n*8,n),'regions':[struct.unpack('<3i',read(p,reg+12*r,12)) for r in range(counts[c])],'order':i(p,lpc+0x80),'polyBefore':ds(p,q(p,lpc),q(p,lpc+8))})
 s['pending']=(obj,item);return False
def end(f,bp,_):
 if not s['pending']:return False
 p=f.GetThread().GetProcess();obj,item=s['pending'];n=item['n'];ptr=q(p,obj+0x250)
 for c,d in enumerate(item['ch']):
  reg=q(p,q(p,obj+0x2f0)+c*24);lpc=q(p,obj+0x178)+c*0x88
  d['output']=ds(p,ptr+c*n*8,n);d['regionsAfter']=[struct.unpack('<3i',read(p,reg+12*r,12)) for r in range(len(d['regions']))];d['polyAfter']=ds(p,q(p,lpc),q(p,lpc+8))
 s['calls'].append(item);s['pending']=None
 if len(s['calls'])>=limit:
  for bp in s['bps'].values():bp.SetEnabled(False)
 return False
def finish(debugger,command,result,internal_dict):
 (root/('loop-runtime-'+tag+'.json')).write_text(json.dumps(s['calls'],indent=2))
 result.PutCString('Captured '+str(len(s['calls']))+' repair windows')
def __lldb_init_module(debugger,_):
 debugger.HandleCommand('command script add -f lldb_loop.init loopinit')
 debugger.HandleCommand('command script add -f lldb_loop.finish loopfinish')
