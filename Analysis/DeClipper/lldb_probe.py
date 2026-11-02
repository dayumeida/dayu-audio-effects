import lldb,json,struct,os
from pathlib import Path
root=Path('/Volumes/DayuMedia 4TB/大鱼音频插件开发/大鱼音频效果器/Analysis/DeClipper')
state={}
allcalls=os.environ.get('DECLIP_PROBE_ALL')=='1'
tag=os.environ.get('DECLIP_PROBE_TAG','')
def target(name):return root/(((tag+'-') if tag else '')+name)

def u(p,a,n):
 e=lldb.SBError();b=p.ReadMemory(a,n,e)
 if not e.Success():raise RuntimeError(str(e))
 return b
def q(p,a):return struct.unpack('<Q',u(p,a,8))[0]
def init(debugger,command,result,internal_dict):
 t=debugger.GetSelectedTarget();m=t.FindModule(lldb.SBFileSpec('ERA5_DeClipperFxFactory'));base=m.FindSection('__TEXT').GetLoadAddress(t);state['base']=base
 print('target module base',hex(base))
 bp=t.BreakpointCreateByAddress(base+0x38f34);bp.SetScriptCallbackFunction('lldb_probe.entry');state['entrybp']=bp.GetID()
 bp=t.BreakpointCreateByAddress(base+0x3a1b4);bp.SetScriptCallbackFunction('lldb_probe.leave');state['exitbp']=bp.GetID()
 for off,cb in [(0x3af44,'validation_enter'),(0x3b150,'validation_exit')]:
  bp=t.BreakpointCreateByAddress(base+off);bp.SetScriptCallbackFunction('lldb_probe.'+cb);bp.SetEnabled(False);state.setdefault('validationbps',[]).append(bp.GetID())
 bp=t.BreakpointCreateByAddress(base+0x3ad30);bp.SetScriptCallbackFunction('lldb_probe.segments')
def entry(frame,bp_loc,internal_dict):
 p=frame.GetThread().GetProcess();outer=frame.FindRegister('x0').GetValueAsUnsigned();det=q(p,outer);state['outer']=outer;state['det']=det
 d={'outer':hex(outer),'det':hex(det),'words':[hex(x) for x in struct.unpack('<88Q',u(p,det,0x2c0))]}
 for off in [0xa8,0xd0,0x100]:
  a=q(p,det+off);z=q(p,det+off+8);items=[]
  for o in range(a,z,32):
   lo,hi,arr=struct.unpack('<iiQ',u(p,o,16));items.append({'lo':lo,'hi':hi,'values':struct.unpack('<2d',u(p,arr,16)),'valuesInt':struct.unpack('<4i',u(p,arr,16))})
  d[f'map{off:x}']=items
 a=q(p,outer+0x18);beg=q(p,a);end=q(p,a+8);(target('detector-first-input.f64')).write_bytes(u(p,beg,end-beg))
 (target('detector-runtime-config.json')).write_text(json.dumps(d,indent=2));
 if allcalls:
  with target('detector-inputs.f64').open('ab') as f:f.write(u(p,beg,end-beg))
 if not allcalls:bp_loc.GetBreakpoint().SetEnabled(False)
 return False
def leave(frame,bp_loc,internal_dict):
 p=frame.GetThread().GetProcess();det=state['det'];outer=state['outer'];d={'doubles':{},'ints':{},'arrays':{}}
 for off in [0,8,0x10,0x18,0x20,0x28,0x30,0x50,0x200,0x218,0x2b0,0x2b8]:d['doubles'][hex(off)]=struct.unpack('<d',u(p,det+off,8))[0]
 for off in [0x40,0x44,0x48,0x1f0,0x1f4,0x1f8,0x208,0x20c,0x210]:d['ints'][hex(off)]=struct.unpack('<i',u(p,det+off,4))[0]
 for off in [0x60,0x78,0x230,0x248,0x148,0x160,0x178,0x190,0x1c0,0x1d8,0x280,0x298]:
  a=q(p,det+off);z=q(p,det+off+8);d['arrays'][hex(off)]=struct.unpack('<%dd'%((z-a)//8),u(p,a,z-a))
 (target('detector-runtime-first.json')).write_text(json.dumps(d,indent=2));
 if allcalls:
  row=[d['arrays'][hex(off)][0] for off in [0x148,0x160,0x178,0x190,0x280]]+[struct.unpack('<i',u(p,q(p,det+0x1a8),4))[0]]
  with target('detector-results.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
 if not allcalls:bp_loc.GetBreakpoint().SetEnabled(False)
 return False
def segments(frame,bp_loc,internal_dict):
 p=frame.GetThread().GetProcess();outer=state['outer'];rootptr=q(p,outer+0x48);a=q(p,rootptr);z=q(p,rootptr+8);rows=[]
 for at in range(a,z,12):rows.append(struct.unpack('<3i',u(p,at,12)))
 out={'regions':rows,'scale':struct.unpack('<d',u(p,outer+0x68,8))[0],'flags':list(u(p,outer+0x70,2)),'maximumRegion':struct.unpack('<i',u(p,outer+0x14,4))[0]}
 with target('regions.jsonl').open('a') as f:f.write(json.dumps(out)+'\n')
 state['segmentsSeen']=state.get('segmentsSeen',0)+1
 if state['segmentsSeen'] in [6,7]:
  for bid in state['validationbps']:frame.GetThread().GetProcess().GetTarget().FindBreakpointByID(bid).SetEnabled(state['segmentsSeen']==6)
 return False

def validation_enter(frame,bp_loc,internal_dict):
 state.pop('validation',None)
 if state.get('segmentsSeen',0)!=6:return False
 p=frame.GetThread().GetProcess();chan=frame.FindRegister('w1').GetValueAsUnsigned();args=frame.FindRegister('x2').GetValueAsUnsigned()
 if chan!=0:return False
 first,second=struct.unpack('<2i',u(p,args,8))
 if max(first,second)<5200:return False
 state['validation']={'first':first,'second':second}
 return False

def validation_exit(frame,bp_loc,internal_dict):
 if 'validation' not in state:return False
 p=frame.GetThread().GetProcess();d=state.pop('validation');d['accepted']=frame.FindRegister('w0').GetValueAsUnsigned();outer=state['outer'];rootptr=q(p,outer+0x48);a=q(p,rootptr);z=q(p,rootptr+8)
 d['last']=struct.unpack('<3i',u(p,z-12,12)) if z>a else None
 with target('validation.jsonl').open('a') as f:f.write(json.dumps(d)+'\n')
 return False

def __lldb_init_module(debugger,internal_dict):debugger.HandleCommand('command script add -f lldb_probe.init declipinit')
