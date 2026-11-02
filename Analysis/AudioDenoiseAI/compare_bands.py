from pathlib import Path
import numpy as np,math,json
root=Path(__file__).parent
class Biquad:
 def __init__(self,f,high=False,ap=False):
  w=2*math.pi*f/64000;c=math.cos(w);s=math.sin(w);a=s*.7071067932881648;n=1/math.fma(s,.7071067932881648,1.)
  self.a1=-2*c*n;self.a2=math.fma(-a,n,n);self.b0=(math.fma(c,.5,.5) if high else math.fma(-c,.5,.5))*n;self.b1=-(1+c)*n if high else math.fma(-c,n,n);self.b2=self.b0
  if ap:self.a1=-2*c/(1+s);self.a2=(1-s)/(1+s);self.b0,self.b1,self.b2=self.a2,self.a1,1
  self.z1=self.z2=0.;self.den=1.e-8
 def run(self,x):
  w=math.fma(self.z2,self.a2,self.den);w=math.fma(self.z1,self.a1,w);w=float(x)-w
  y=self.z2*self.b2;y=math.fma(self.z1,self.b1,y);y=math.fma(w,self.b0,y)
  self.z2,self.z1=self.z1,w;self.den=-self.den;return np.float32(y)
l1,l2,h1,h2=Biquad(500),Biquad(500),Biquad(500,1),Biquad(500,1)
m1,m2,n1,n2=Biquad(4000),Biquad(4000),Biquad(4000,1),Biquad(4000,1);ap=Biquad(4000,ap=True)
out=np.zeros((3,16384),np.float32)
for j in range(16384):
 x=float(j==0);low=l2.run(l1.run(x));hi=h2.run(h1.run(x));out[0,j]=ap.run(low);out[1,j]=m2.run(m1.run(hi));out[2,j]=n2.run(n1.run(hi))
rows=[]
for i in range(3):
 ref=np.fromfile(root/f'reference-band-{i}.f32',np.float32);d=out[i]-ref
 rows.append({'band':i,'maxError':float(np.max(abs(d))),'RMSError':float(np.sqrt(np.mean(d*d))),'sampleCount':len(d)})
(root/'band-comparison.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
