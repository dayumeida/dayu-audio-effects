from pathlib import Path
import struct, json
import numpy as np
root=Path('Outputs/破音素材试听')
def read(path):
    b=path.read_bytes(); p=12; fmt=None; data=None
    while p+8<=len(b):
        tag=b[p:p+4]; n=struct.unpack_from('<I',b,p+4)[0]; chunk=b[p+8:p+8+n]
        if tag==b'fmt ': fmt=struct.unpack_from('<HHIIHH',chunk)
        if tag==b'data': data=chunk
        p+=8+n+(n&1)
    assert fmt is not None and data is not None and fmt[0] in (3,65534) and fmt[5]==32, (path,fmt)
    return np.frombuffer(data,dtype='<f4').reshape(-1,fmt[1]).astype(np.float64),fmt[2]
x,rate=read(root/'原始素材.wav'); x=x[:,0]
clipped=np.abs(x)>=.999999
starts=np.flatnonzero(clipped & ~np.r_[False,clipped[:-1]])
ends=np.flatnonzero(clipped & ~np.r_[clipped[1:],False])+1
plateaus=[(int(a),int(b)) for a,b in zip(starts,ends) if b-a>=3]
report={'sampleRate':rate,'frames':len(x),'digitalFullScaleSamples':int(clipped.sum()),'plateausAtLeast3Samples':len(plateaus),'longestPlateau':max((b-a for a,b in plateaus),default=0),'modes':[]}
for path in sorted(root.glob('破音修复_*.wav')):
    y,_=read(path); y=y[:,0]; gain=float(np.dot(x,y)/np.dot(x,x)); residual=y-gain*x
    report['modes'].append({'file':path.name,'leastSquaresGain':gain,'correlation':float(np.corrcoef(x,y)[0,1]),'residualOverOutputRMS':float(np.sqrt(np.mean(residual*residual)/np.mean(y*y))),'inputFullScaleSamplesStillFlatAt3SampleScale':sum(float(np.std(y[a:b]))<1e-7 for a,b in plateaus),'sameRMSRmsDifferenceDbFS':float(20*np.log10(np.sqrt(np.mean((y/(np.sqrt(np.mean(y*y)))*np.sqrt(np.mean(x*x))-x)**2))+1e-15))})
Path('Analysis/MultiEffect/UserClip/waveform-differences.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
