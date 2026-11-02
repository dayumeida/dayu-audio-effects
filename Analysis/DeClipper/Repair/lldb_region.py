import lldb,json,struct
from pathlib import Path
root=Path('/Volumes/DayuMedia 4TB/大鱼音频插件开发/大鱼音频效果器/Analysis/DeClipper/Repair')
s={'dual':[],'spline':[],'pendingDual':None,'pendingSpline':None,'bps':{}}
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
 for addr,fn in [(0x2a4a8,'dual_entry'),(0x2befc,'dual_exit'),(0x6aaf4,'spline_entry'),(0x6aed0,'spline_exit')]:
  bp=t.BreakpointCreateByAddress(base+addr);bp.SetScriptCallbackFunction('lldb_region.'+fn);s['bps'][fn]=bp

def dual_entry(f,bp,_):
 if len(s['dual'])>=8:return False
 p=f.GetThread().GetProcess();obj=f.FindRegister('x0').GetValueAsUnsigned();r=f.FindRegister('w1').GetValueAsUnsigned();ch=f.FindRegister('w2').GetValueAsUnsigned();primary=f.FindRegister('w3').GetValueAsUnsigned();secondary=f.FindRegister('w4').GetValueAsUnsigned()
 vec=q(p,obj+0x2f0)+ch*24;reg=q(p,vec)+r*12;kind,start,end=struct.unpack('<3i',read(p,reg,12));n=q(p,obj+0x258);ctx=i(p,obj+0x2b4);left=min(start,ctx);right=min(n-end-1,ctx);beg=q(p,obj+0x250)+(ch*n+start-left)*8;length=left+end-start+1+right;lpc=q(p,obj+0x178)+ch*0x88
 d={'call':len(s['dual']),'regionIndex':r,'channel':ch,'kind':kind,'start':start,'end':end,'context':ctx,'left':left,'right':right,'primary':primary,'secondary':secondary,'input':ds(p,beg,length),'allocatedOrder':i(p,lpc+0x84),'order':i(p,lpc+0x80),'polynomialBefore':ds(p,q(p,lpc),q(p,lpc+8))}
 s['pendingDual']=(obj,beg,length,lpc,d);return False

def dual_exit(f,bp,_):
 if not s['pendingDual']:return False
 p=f.GetThread().GetProcess();obj,beg,n,lpc,d=s['pendingDual'];d['output']=ds(p,beg,n);d['result']=f.FindRegister('w24').GetValueAsUnsigned();d['polynomialAfter']=ds(p,q(p,lpc),q(p,lpc+8));l=d['end']-d['start']+1
 for off in [0x1b0,0x1c0,0x1d0,0x1e0,0x210]:d[hex(off)]=ds(p,q(p,obj+off),l)
 s['dual'].append(d);s['pendingDual']=None;(root/'dual-runtime-calls.json').write_text(json.dumps(s['dual'],indent=2))
 if len(s['dual'])>=8:
  for fn in ['dual_entry','dual_exit']:s['bps'][fn].SetEnabled(False)
 return False

def spline_entry(f,bp,_):
 if len(s['spline'])>=8:return False
 p=f.GetThread().GetProcess();obj=f.FindRegister('x0').GetValueAsUnsigned();n=i(p,obj+0x24)
 if n<2:return False
 s['pendingSpline']=(obj,n,{'call':len(s['spline']),'x':ds(p,q(p,obj+0x30),n),'y':ds(p,q(p,obj+0x38),n)})
 return False

def spline_exit(f,bp,_):
 if not s['pendingSpline']:return False
 p=f.GetThread().GetProcess();obj,n,d=s['pendingSpline'];d['slopes']=ds(p,q(p,obj+0x100),n);s['spline'].append(d);s['pendingSpline']=None;(root/'spline-runtime-calls.json').write_text(json.dumps(s['spline'],indent=2))
 if len(s['spline'])>=8:
  for fn in ['spline_entry','spline_exit']:s['bps'][fn].SetEnabled(False)
 return False

def __lldb_init_module(debugger,_):debugger.HandleCommand('command script add -f lldb_region.init regioninit')
