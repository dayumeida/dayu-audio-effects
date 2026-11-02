from pathlib import Path
import onnx,numpy as np,json
root=Path(__file__).parent
m=onnx.load(root/'model.onnx');cs={n.output[0]:onnx.numpy_helper.to_array(n.attribute[0].t) for n in m.graph.node if n.op_type=='Constant'}
shape=json.loads((root/'model-shapes.json').read_text()); shape['Input1']=[1,1,1,16384]
out=[]; desc=[]; macs=0;offset=0
for i in range(20):
 w=cs['W'+str(i)] if i<19 else cs['lastconvw']; oc,ic,_,k=w.shape
 if i<19:
  scale=cs['s'+str(i)]/np.sqrt(cs['var'+str(i)]+np.float32(.001));b=cs['bias'+str(i)]-cs['mean'+str(i)]*scale
  w=w*scale.reshape(-1,1,1,1)
 else:b=cs['lastconvb']
 w=w.astype('<f4').flatten();b=b.astype('<f4').flatten();out.extend([w,b]);woff=offset;offset+=len(w);boff=offset;offset+=len(b)
 if i<10:
  name='act'+str(i);inN=16384 if i==0 else shape['act'+str(i-1)][-1];outN=shape[name][-1];stride=1 if i==0 else 2;skip=-1;crop=0;resize=0
 elif i<19:
  name='act'+str(i);inN=shape['scale'+str(i)][-1];outN=shape[name][-1];stride=1;skip=19-i if i>10 else -1;crop=int(cs['skipstarts'+str(i-1)][3]) if i>10 else 0;resize=1
 else:
  inN=shape['concat18'][-1];outN=8192;stride=1;skip=0;crop=int(cs['skipstarts18'][3]);resize=0
 macs+=outN*oc*ic*k
 desc.append([ic,oc,inN,outN,stride,skip,crop,resize,woff,boff])
np.concatenate(out).tofile(root/'dayu-denoise-weights.bin')
s='// Generated from authenticated AudioDenoise AI 1.0.6 model; see report.md.\n#pragma once\n#include <cstddef>\nnamespace dayu_denoise {\nstruct Layer {int inputs,outputs,inputLength,outputLength,stride,skip,crop,resize; std::size_t weights,bias;};\ninline constexpr Layer layers[20] = {\n'+''.join('    {'+','.join(map(str,d))+'},\n' for d in desc)+'};\ninline constexpr std::size_t weightFloats = '+str(offset)+';\n}\n';(root/'DenoiseModelData.hpp').write_text(s)
print(json.dumps({'macs':macs,'FLOPs':macs*2,'weightsBytes':offset*4,'layers':desc},indent=2))
