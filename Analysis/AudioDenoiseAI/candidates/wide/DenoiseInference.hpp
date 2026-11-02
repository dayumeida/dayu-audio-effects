#pragma once
#include "DenoiseModelData.hpp"
#include "DenoiseMatmul.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <vector>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <string>
namespace dayu_denoise {
// All storage is prepared off the render thread. begin/step/output are allocation-free.
// step() is one output tile (at most 64 time samples in one convolution layer).
class Inference {
public:
 bool prepare(const char *path) {
  {
   // Only preparation touches the cache; rendering reads the immutable raw pointer.
   static std::mutex cacheMutex;
   static std::unordered_map<std::string,std::weak_ptr<const std::vector<float>>>cache;
   const std::string key(path?path:"");std::lock_guard<std::mutex>lock(cacheMutex);
   owner_=cache[key].lock();
   if(!owner_){auto data=std::make_shared<std::vector<float>>(weightFloats);std::ifstream f(key,std::ios::binary);
    if(!f.read(reinterpret_cast<char*>(data->data()),data->size()*sizeof(float)))return ready=false;
    owner_=data;cache[key]=data;
   }
   weights=owner_->data();
  }
  for(int i=0;i<20;++i){features[i].resize(layers[i].outputs*layers[i].outputLength); if(layers[i].resize){mapping[i].resize(layers[i].inputLength); for(int x=0;x<layers[i].inputLength;++x){float y=float(x)*float(layers[i].inputLength/2-1)/float(layers[i].inputLength-1);mapping[i][x]=int(std::ceil(y-.5f));}}}
  columns.resize(1024*9*tile); product.resize(512*tile); ready=true;
  begin(raw.data()); while(busy())step(); reset();
  return true;
 }
 bool begin(const float *input) noexcept {
  if(!ready || active)return false; std::memcpy(raw.data(),input,16384*sizeof(float)); layer=0;position=0;channel=0;active=true;return true;
 }
 void reset() noexcept { active=false;layer=0;position=0;channel=0; }
 bool busy() const noexcept{return active;}
 int currentLayer() const noexcept {return layer;}
 // Return true after the complete graph has produced a new 16384-sample waveform.
 bool step() noexcept {
  if(!active)return false;
  const auto &d=layers[layer];const int n=std::min(tile,d.outputLength-position);const int rows=std::min(rowWidth(d,n),d.outputs-channel); const int k=d.inputs*9;const int padded=(n+3)&~3;
  if(channel==0)for(int ic=0;ic<d.inputs;++ic)for(int j=0;j<9;++j){
   float *col=columns.data()+(ic*9+j)*padded;
   for(int x=0;x<n;++x)col[x]=read(ic,(position+x)*d.stride+j);for(int x=n;x<padded;++x)col[x]=0;
  }
  matmul(weights+d.weights+channel*k,columns.data(),product.data(),rows,padded,k);
  for(int oc=0;oc<rows;++oc){
   float *dest=features[layer].data()+(channel+oc)*d.outputLength+position;const float bias=weights[d.bias+channel+oc];
   for(int x=0;x<n;++x){float v=product[oc*padded+x]+bias;
    if(layer<10)v=v>=0?v:v*.2f;
    else if(layer<19)v=v/(1.f+std::exp(-v));
    dest[x]=v;
   }
  }
  channel+=rows;if(channel==d.outputs){channel=0;position+=n;}
  if(position==d.outputLength){position=0;if(++layer==20){
   for(int x=0;x<16384;++x)result[x]=raw[x]+((x>=4096&&x<12288)?features[19][x-4096]:0.f);
   active=false;return true;
  }}
  return false;
 }
 const float *output()const noexcept{return result.data();}
 const float *activation(int i)const noexcept{return features[i].data();}
 static constexpr int tile=64;
 static int rowWidth(const Layer&d,int n)noexcept{return d.outputs<4?d.outputs:std::max(4,std::min(d.outputs,(8000000/(n*d.inputs*9)/4)*4));}
 double nextStepCost() const noexcept {if(!active)return 0;const auto&d=layers[layer];const int n=std::min(tile,d.outputLength-position);return double(n)*std::min(rowWidth(d,n),d.outputs-channel)*d.inputs*9+10000;}
 static double totalCost() noexcept {double cost=0;for(const auto&d:layers)cost+=double(d.outputLength)*d.inputs*9*d.outputs;return cost+stepCount()*10000.;}
 static int stepCount() noexcept {int count=0;for(const auto&d:layers)for(int x=0;x<d.outputLength;x+=tile){int rows=rowWidth(d,std::min(tile,d.outputLength-x));count+=(d.outputs+rows-1)/rows;}return count;}

private:
 float read(int c,int x) const noexcept {
  const auto &d=layers[layer];
  if(layer==0)return raw[x];
  if(layer<10)return features[layer-1][c*layers[layer-1].outputLength+x];
  // ONNX nearest, align_corners, round_prefer_floor. Exact rational avoids drift.
  if(d.resize)x=mapping[layer][x];
  const auto &prev=layers[layer-1];
  if(c<prev.outputs)return features[layer-1][c*prev.outputLength+x];
  const auto &skip=layers[d.skip];return features[d.skip][(c-prev.outputs)*skip.outputLength+x+d.crop];
 }
 std::shared_ptr<const std::vector<float>>owner_;const float*weights=nullptr;std::vector<float>columns,product;
 std::array<std::vector<float>,20>features;
 std::array<std::vector<int>,20>mapping;
 std::array<float,16384>raw{},result{};
 int layer=0,position=0,channel=0;bool ready=false,active=false;
};
}
