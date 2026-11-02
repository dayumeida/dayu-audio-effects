import lldb,json,struct
from pathlib import Path
r=Path('/Volumes/DayuMedia 4TB/大鱼音频插件开发/大鱼音频效果器/Analysis/DeClipper');state={'calls':0}
def mem(p,a,n):
 e=lldb.SBError();b=p.ReadMemory(a,n,e)
 if not e.Success():raise RuntimeError(str(e))
 return b
def q(p,a):return struct.unpack('<Q',mem(p,a,8))[0]
def init(debugger,cmd,result,internal):
 t=debugger.GetSelectedTarget();m=t.FindModule(lldb.SBFileSpec('ERA5_DeClipperFxFactory'));b=m.FindSection('__TEXT').GetLoadAddress(t)
 for off,cb in [(0x46a9c,'enter'),(0x470c0,'leave')]:
  bp=t.BreakpointCreateByAddress(b+off);bp.SetScriptCallbackFunction('lldb_limiter.'+cb)
def enter(frame,bp,internal):
 p=frame.GetThread().GetProcess();a=frame.FindRegister('x0').GetValueAsUnsigned();ptr=frame.FindRegister('x1').GetValueAsUnsigned();n=frame.FindRegister('w2').GetValueAsUnsigned();c=frame.FindRegister('w3').GetValueAsUnsigned();state.update({'a':a,'buffers':[q(p,ptr+8*i)for i in range(c)],'n':n,'c':c})
 with(r/'limiter-input.f32').open('ab')as f:
  for b in state['buffers']:f.write(mem(p,b,n*4))
 if state['calls']==0:
  d={'frames':n,'channels':c,'floats':struct.unpack('<24f',mem(p,a,96)),'ints':struct.unpack('<24I',mem(p,a,96)),'envelopes':{}}
  for off in [0x68,0x70,0x78]:d['envelopes'][hex(off)]={'raw':mem(p,q(p,a+off),64).hex(),'vtable':hex(q(p,q(p,a+off)))}
  (r/'limiter-initial-state.json').write_text(json.dumps(d,indent=2))
 return False
def leave(frame,bp,internal):
 p=frame.GetThread().GetProcess()
 with(r/'limiter-output.f32').open('ab')as f:
  for b in state['buffers']:f.write(mem(p,b,state['n']*4))
 state['calls']+=1
 return False
def __lldb_init_module(d,i):d.HandleCommand('command script add -f lldb_limiter.init limiterinit')
