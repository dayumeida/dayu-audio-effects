import lldb,json,struct,os
from pathlib import Path
root=Path('/Volumes/DayuMedia 4TB/大鱼音频插件开发/大鱼音频效果器/Analysis/DeClipper/Repair')
tag=os.getenv('DAYU_LONG_TAG','')
st={'entries':[],'pending':None,'bps':[],'windows':0}
def read(p,a,n):
 e=lldb.SBError();b=p.ReadMemory(a,n,e)
 if not e.Success():raise RuntimeError(str(e))
 return b
def q(p,a):return struct.unpack('<Q',read(p,a,8))[0]
def ds(p,a,n):return list(struct.unpack('<%dd'%n,read(p,a,8*n))) if n else []
def init(debugger,command,result,internal_dict):
 t=debugger.GetSelectedTarget();m=t.FindModule(lldb.SBFileSpec('ERA5_DeClipperFxFactory'));base=m.FindSection('__TEXT').GetLoadAddress(t);st['base']=base
 for addr,fn in [(0x43348,'entry'),(0x435f4,'mean'),(0x449f8,'leave')]:
  bp=t.BreakpointCreateByAddress(base+addr);bp.SetScriptCallbackFunction('lldb_long.'+fn);bp.SetEnabled(False);st['bps'].append(bp)
 bp=t.BreakpointCreateByAddress(base+0x2bf60);bp.SetScriptCallbackFunction('lldb_long.window');st['windowbp']=bp
def window(frame,bp_loc,internal_dict):
 st['windows']+=1
 if st['windows']==29:
  st['bps'][0].SetEnabled(True);st['windowbp'].SetEnabled(False)
 return False
def entry(frame,bp_loc,internal_dict):
 if len(st['entries'])>=8:bp_loc.GetBreakpoint().SetEnabled(False);return False
 p=frame.GetThread().GetProcess();regs=[frame.FindRegister('x'+str(i)).GetValueAsUnsigned() for i in range(8)]
 x0,x1,x2,x3,x4,x5,x6,x7=regs; a=q(p,x2);n=q(p,x2+8)
 if (x3&0xffffffff)<100:return False
 for bp in st['bps'][1:]:bp.SetEnabled(True)
 d={'call':len(st['entries']),'regs':[hex(x) for x in regs],'inputLen':n,'inputAddress':hex(a),'predictLen':x3&0xffffffff,'estimate':x7&0xffffffff,'order':struct.unpack('<i',read(p,x1+0x80,4))[0], 'input':ds(p,a,n),'polyBefore':ds(p,q(p,x1),q(p,x1+8)),'lpcObjectWords':[hex(x) for x in struct.unpack('<17Q',read(p,x1,0x88))]}
 st['pending']=(regs,d);return False
def mean(frame,bp_loc,internal_dict):
 if st['pending']:
  e=lldb.SBError();st['pending'][1]['mean']=frame.FindRegister('d3').GetData().GetDouble(e,0)
 return False
def leave(frame,bp_loc,internal_dict):
 if st['pending'] is None:return False
 p=frame.GetThread().GetProcess();regs,d=st['pending'];x0,x1,x2,x3,x4,x5,x6,x7=regs
 a=q(p,x0);n=q(p,x0+8);d['output']=ds(p,a,n)
 for off in [0,0x10,0x20,0x30,0x40,0x50,0x60]:
  beg=q(p,x1+off);n=q(p,x1+off+8)
  if 0<=n<100000:d['lpc'+hex(off)]=ds(p,beg,n)
 d['residualExtended']=ds(p,q(p,x1+0x30),max(d['predictLen'],q(p,x1+0x38)))
 words=struct.unpack('<17Q',read(p,x1+0x88,0x88));d['nextLPCObjectWords']=[hex(v)for v in words]
 if words[-1]==0x9600000064:
  for off in [0,0x10,0x20,0x30,0x40,0x50,0x60,0x70]:d['nextLPC'+hex(off)]=ds(p,q(p,x1+0x88+off),q(p,x1+0x90+off))
 st['entries'].append(d);st['pending']=None
 for bp in st['bps'][1:]:bp.SetEnabled(False)
 if len(st['entries'])>=8:
  for bp in st['bps']:bp.SetEnabled(False)
 (root/('lpc-long'+tag+'-runtime-calls.json')).write_text(json.dumps(st['entries'],indent=2));return False
def __lldb_init_module(debugger,internal_dict):debugger.HandleCommand('command script add -f lldb_long.init longinit')
