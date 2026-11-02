from pathlib import Path
import json,struct,bisect,math
r=Path(__file__).parent
raw=(r/'detector-first-input.f64').read_bytes();x=list(struct.unpack('<%dd'%(len(raw)//8),raw));j=json.loads((r/'detector-runtime-first.json').read_text());actual=j['arrays']
N=6530;k=34
x=[v if abs(v)>1e-7 else 0.0 for v in x]
edges=[min(x)];step=(max(x)-min(x))/(N-1)
for i in range(1,N):edges.append(edges[-1]+step)
h=[0.0]*N
for v in x:h[min(N-1,bisect.bisect_left(edges,v))]+=1
print('edges error',max(abs(a-b) for a,b in zip(edges,actual['0x78'])),'hist raw error',max(abs(a-b) for a,b in zip(h,actual['0x230'])))
# source 39380...39558: filter histogram endpoints with a running mean plus reduced support ends.
for i in range(k and 2448,N-2448):h[i]=0.0
temp=h[:k]+h
s=0.;smooth=[0.]*N;out=0
for i,v in enumerate(temp):
 s+=v
 if i>=k:
  s-=temp[i-k];smooth[out]=s/(k-1);out+=1
p=0;s=0.
for i in range(k-3):
 s+=temp[k+i]
 if i%2==0:smooth[p]=s/(i+1);p+=1
start=k-2;smooth[p+1:p+1+(N-start)]=smooth[start:]
last=N-1;s=0.;count=1
for current in range(N,N-k+3,-1):
 s+=temp[k-1+current]
 if (current-1)%2:
  smooth[last]=s/count;last-=1
 count+=1
print('smooth error',max(abs(a-b) for a,b in zip(smooth,actual['0x248'])))
for i,(a,b) in enumerate(zip(smooth,actual['0x248'])):
 if abs(a-b)>1e-12:
  print('first',i,a,b);break
# threshold primitive branch; default type0.
left=max(range(2448),key=lambda i:smooth[i]);right=max(range(N-2448,N),key=lambda i:smooth[i])
ll=0
for i in range(left,0,-1):
 if smooth[i]<=.25*smooth[left]:ll=i;break
lr=2448
for i in range(left,2448):
 if smooth[i]<=.25*smooth[left]:lr=i;break
rl=N-2448
for i in range(right,N-2448,-1):
 if smooth[i]<=.25*smooth[right]:rl=i;break
rr=N-1
for i in range(right+1,N):
 if smooth[i]<=.25*smooth[right]:rr=i-1;break
print('peaks',left,right,'sides',ll,lr,rl,rr)
# width interpolation uses integer truncation.
def off(width):
 width=max(1,min(2447,width))
 return (65 if width<32 else int(65+(97-65)*(width-32)//(2448-32)))**1.25
neg=edges[min(N-1,int(left+off(max(1,lr-ll))))];pos=edges[max(0,int(right-off(max(1,rr-rl))))]
print('threshold',neg,pos,'actual',actual['0x160'][0],actual['0x148'][0])
(r/'detector-draft-first.json').write_text(json.dumps({'edges':edges,'histogram':h,'smoothed':smooth,'peaks':[left,right],'sides':[ll,lr,rl,rr],'negative':neg,'positive':pos},indent=2))
