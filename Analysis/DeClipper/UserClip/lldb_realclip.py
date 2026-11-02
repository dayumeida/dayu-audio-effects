import lldb,json,struct,os
from pathlib import Path
root=Path('/Volumes/DayuMedia 4TB/大鱼音频插件开发/大鱼音频效果器/Analysis/DeClipper/UserClip')
s={'windows':[],'segments':[],'detection':[],'pending':None};tag=os.getenv('DECLIP_REAL_TAG','q0-t0')
def read(p,a,n):
 e=lldb.SBError();b=p.ReadMemory(a,n,e)
 if not e.Success():raise RuntimeError(str(e))
 return b
def q(p,a):return struct.unpack('<Q',read(p,a,8))[0]
def i(p,a):return struct.unpack('<i',read(p,a,4))[0]
def ds(p,a,n):return struct.unpack('<%dd'%n,read(p,a,n*8))if n else ()
def init(d,cmd,r,_):
 t=d.GetSelectedTarget();base=t.FindModule(lldb.SBFileSpec('ERA5_DeClipperFxFactory')).FindSection('__TEXT').GetLoadAddress(t)
 for off,fn in [(0x38f34,'detentry'),(0x3a1b4,'detend'),(0x3ad30,'segments'),(0x2bf60,'entry'),(0x2d858,'end')]:t.BreakpointCreateByAddress(base+off).SetScriptCallbackFunction('lldb_realclip.'+fn)
def detentry(f,b,_):s['outer']=f.FindRegister('x0').GetValueAsUnsigned();return False
def detend(f,b,_):
 p=f.GetThread().GetProcess();det=q(p,s['outer']);v={}
 for off,name in [(0x148,'positive'),(0x160,'negative'),(0x178,'positiveTolerance'),(0x190,'negativeTolerance'),(0x280,'rms')]:v[name]=ds(p,q(p,det+off),2)
 v['extent']=struct.unpack('<2i',read(p,q(p,det+0x1a8),8));s['detection'].append(v);return False
def segments(f,b,_):
 p=f.GetThread().GetProcess();r=q(p,s['outer']+0x48);a=q(p,r);z=q(p,r+8);regions=[struct.unpack('<3i',read(p,at,12))for at in range(a,z,12)];s['segments'].append({'regions':regions,'scale':ds(p,s['outer']+0x68,1)[0]});return False
def entry(f,b,_):
 p=f.GetThread().GetProcess();obj=f.FindRegister('x0').GetValueAsUnsigned();n=q(p,obj+0x258);ptr=q(p,obj+0x250);count=i(p,q(p,obj+0x2c8));reg=q(p,q(p,obj+0x2f0));regions=[struct.unpack('<3i',read(p,reg+12*k,12))for k in range(count)];s['pending']=(obj,n,ptr,regions,ds(p,ptr,n));return False
def end(f,b,_):
 if not s['pending']:return False
 p=f.GetThread().GetProcess();obj,n,ptr,regions,before=s['pending'];after=ds(p,ptr,n);reg=q(p,q(p,obj+0x2f0));rAfter=[struct.unpack('<3i',read(p,reg+12*k,12))for k in range(len(regions))];s['windows'].append({'window':len(s['windows'])+1,'regionsBefore':regions,'regionsAfter':rAfter,'changedSamplesFullWindow':sum(x!=y for x,y in zip(before,after)),'repairedPeak':max(map(abs,after)),'preRepairPeak':max(map(abs,before))});s['pending']=None;return False
def finish(d,cmd,r,_):(root/('original-internals-'+tag+'.json')).write_text(json.dumps(s,indent=2));r.PutCString('saved original normal AU internals '+tag)
def __lldb_init_module(d,_):d.HandleCommand('command script add -f lldb_realclip.init realinit');d.HandleCommand('command script add -f lldb_realclip.finish realfinish')
