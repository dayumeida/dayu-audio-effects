#import <AudioToolbox/AudioToolbox.h>
#include <vector>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
int main(){AudioComponentDescription d{'aufx','adai','CPop',0,0};AudioUnit au=nullptr;AudioComponentInstanceNew(AudioComponentFindNext(nullptr,&d),&au);void*h=dlopen("/Library/Audio/Plug-Ins/Components/AudioDenoise AI.component/Contents/MacOS/AudioDenoise AI",RTLD_NOW);void*f=dlsym(h,"AudioDenoiseAIFactory");Dl_info info{};dladdr(f,&info);char*base=(char*)info.dli_fbase;void*obj=calloc(1,0x58);
using Ctor=void(*)(void*,int,int,std::vector<float>);using Split=std::vector<std::vector<float>>&(*)(void*,const std::vector<float>&);using Dtor=void(*)(void*);
std::vector<float>in(16384);in[0]=1;((Ctor)(base+0x5bead4))(obj,64000,16384,{500,4000});double*lr=(double*)(*(char**)((char*)obj+8)+8);printf("LR ");for(int c=0;c<9;++c)printf("%.12g ",lr[c]);puts("");auto*apgroups=(std::vector<std::vector<unsigned char>>*)((char*)obj+0x20);auto*groups=(std::vector<std::vector<char>>*)((char*)obj+0x20);(void)apgroups;for(size_t g=0;g<groups->size();++g){auto&v=(*groups)[g];double*coeff=(double*)v.data();printf("APgroup %zu bytes %zu ",g,v.size());for(int c=0;c<6;++c)printf("%.12g ",coeff[c]);puts("");}
auto&bands=((Split)(base+0x5bf5c8))(obj,in);printf("bands %zu\n",bands.size());for(size_t i=0;i<bands.size();++i){char path[512];snprintf(path,sizeof(path),"Analysis/AudioDenoiseAI/reference-band-%zu.f32",i);FILE*out=fopen(path,"wb");fwrite(bands[i].data(),4,bands[i].size(),out);fclose(out);}((Dtor)(base+0x5bf974))(obj);free(obj);AudioComponentInstanceDispose(au);}
