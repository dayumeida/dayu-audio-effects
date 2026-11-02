#pragma once
// ERA5 De-Clipper 5.4.00 arm64 detector reconstruction.
// Continuous-window double comparisons and whole-AU checks are in this directory.
// Static sources: func-36bac.asm, func-38f34.asm. Runtime verification: detector-runtime*.json.
#include <vector>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
namespace dayu::declip {
class RecoveredDetector {
public:
 struct Result { double positive=0, negative=0, positiveTolerance=0, negativeTolerance=0, rms=0; int extent=0; };
 void prepare(double rate) {
  sampleRate=rate;ratio=rate/44100.;
  // The original constructor scales histogram count once and its smoothing width twice.
  bins=std::max(2,int(6000.*rate/44100.));
  smooth=std::max(1,int(double(int(double(6000.f*0.005f)*ratio))*rate/44100.));
  search=std::max(1,std::min(bins/2,int(.75*std::floor(bins*.5))));
  a=std::max(2,int(30.*ratio)); b=std::max(2,int(60.*ratio)); c=std::max(b+1,int(90.*ratio));
  map1={1,std::max(2,int(10.*ratio)),std::max(3,int(50.*ratio)),std::max(4,int(175.*ratio)),search};
  map2={1,b,std::max(b+1,int(70.*ratio)),std::max(b+2,int(80.*ratio)),c};
  edges.resize(bins);hist.resize(bins);temp.resize(bins+smooth);before.resize(bins);after.resize(bins);
  reset();
 }
 void reset() noexcept { results={};priorPositive={};priorNegative={};priorRMS={}; }
 int binCount() const noexcept {return bins;}
 int smoothingWidth() const noexcept {return smooth;}
 const std::vector<double>& binEdges()const noexcept{return edges;}
 const std::vector<double>& rawHistogram()const noexcept{return before;}
 const std::vector<double>& smoothedHistogram()const noexcept{return after;}
 const Result& process(double* input,int count,unsigned channel,bool type2) noexcept {
  channel=std::min(channel,1u);auto& out=results[channel];
  const double exponent=type2?double(1.4199999570846558):1.25;
  const double toleranceFactor=type2?850.:750.;
  double sum=0.,lo=0.,hi=0.;
  if(count>0){lo=hi=std::abs(input[0])<=1e-7?0.:input[0];}
  for(int i=0;i<count;++i){double v=input[i];if(std::abs(v)<=1e-7)v=0.;input[i]=v;sum+=v*v;lo=std::min(lo,v);hi=std::max(hi,v);}
  double rms=count>0?std::sqrt(sum/count):0.;
  rms=.25*rms+.75*priorRMS[channel];
  const double rmsRatio=priorRMS[channel]>rms?rms/priorRMS[channel]:1.;priorRMS[channel]=rms;out.rms=rms;
  std::fill(hist.begin(),hist.end(),0.);
  double step=(hi-lo)/(bins-1);if(step==0. && hi-lo!=0.)step=1.;
  double edge=lo;for(int i=0;i<bins;++i){edges[i]=edge;edge+=step;}
  if(edges[0]<edges[1]){
   for(int i=0;i<count;++i){auto p=std::lower_bound(edges.begin(),edges.end(),input[i]);int at=p==edges.end()?bins-1:int(p-edges.begin());hist[at]+=1.;}
  }
  std::copy(hist.begin(),hist.end(),before.begin());
  if(smooth>1) {
   for(int i=search;i<bins-search;++i)hist[i]=0.;
   std::copy(hist.begin(),hist.end(),temp.begin()+smooth);
   std::copy(hist.begin(),hist.begin()+std::min(smooth,bins),temp.begin());
   double accum=0.;int dest=0;
   for(int i=0;i<bins+smooth;++i){accum+=temp[i];if(i>=smooth){accum-=temp[i-smooth];hist[dest++]=accum/(smooth-1);}}
   int prefix=0;accum=0.;
   for(int i=0;i<smooth-3;++i){accum+=temp[smooth+i];if((i&1)==0)hist[prefix++]=accum/(i+1);}
   const int start=smooth-2;
   if(start<bins && prefix+1<bins)std::memmove(hist.data()+prefix+1,hist.data()+start,size_t(bins-start)*sizeof(double));
   int last=bins-1,n=1;accum=0.;
   for(int current=bins;current>bins-smooth+3;--current){accum+=temp[smooth-1+current];if((current-1)&1)hist[last--]=accum/n;++n;}
  }
  std::copy(hist.begin(),hist.end(),after.begin());
  int left=int(std::max_element(hist.begin(),hist.begin()+search)-hist.begin());
  int right=int(std::max_element(hist.end()-search,hist.end())-hist.begin());
  int ll=0,lr=search,rl=bins-search,rr=bins-1;
  double leftPeak=hist[left],rightPeak=hist[right];
  for(int i=left;i>0;--i)if(hist[i]<=.25*leftPeak){ll=i;break;}
  for(int i=left;i<search;++i)if(hist[i]<=.25*leftPeak){lr=i;break;}
  for(int i=right;i>bins-search;--i)if(hist[i]<=.25*rightPeak){rl=i;break;}
  for(int i=right+1;i<bins;++i)if(hist[i]<=.25*rightPeak){rr=i-1;break;}
  bool secondaryLeft=false,secondaryRight=false;int centerLeft=-1,centerRight=-1;
  if(type2 && edges[0]<0.) {
   double best=-1.;
   for(int i=30;i<search;++i){const double v=double(float(after[i]));if(v>best && v<leftPeak){centerLeft=i;best=v;}}
   if(centerLeft>=1 && lr+10<centerLeft && after[centerLeft]>2.){
    left=centerLeft;leftPeak=best;secondaryLeft=true;ll=0;lr=search;
    for(int i=left;i>0;--i)if(after[i]<=.25*leftPeak){ll=i;break;}
    for(int i=left;i<search;++i)if(after[i]<=.25*leftPeak){lr=i;break;}
   }
   best=-1.;
   for(int i=bins-31;i>bins-search-1;--i){const double v=double(float(after[i]));if(v>best && v<rightPeak){centerRight=i;best=v;}}
   if(centerRight>=1 && rl>centerRight+10 && after[centerRight]>2.){
    right=centerRight;rightPeak=best;secondaryRight=true;rl=bins-search;rr=bins-1;
    for(int i=right+1;i<bins;++i)if(after[i]<=.25*rightPeak){rr=i-1;break;}
    for(int i=right;i>bins-search;--i)if(after[i]<=.25*rightPeak){rl=i;break;}
   }
  }
  const int leftWidth=std::max(1,lr-ll),rightWidth=std::max(1,rr-rl);
  const double leftOffset=std::pow(double(offsetTable(leftWidth)),exponent);
  const double rightOffset=std::pow(double(offsetTable(rightWidth)),exponent);
  const double leftTolerance=toleranceFactor*widthTable(leftWidth);
  const double rightTolerance=toleranceFactor*widthTable(rightWidth);
  out.extent=int(std::floor(.5*(extentTable(int(leftOffset))+extentTable(int(rightOffset)))));
  double neg=edges[std::clamp(int(left+leftOffset),0,bins-1)];if(!(neg<0.))neg=edges[left];
  double pos=edges[std::clamp(int(right-rightOffset),0,bins-1)];if(!(pos>0.))pos=edges[right];
  if(std::abs(neg)>.75*std::abs(priorNegative[channel])){
   out.negative=neg;out.negativeTolerance=leftTolerance*(edges[ll]-edges[lr]);
   if(std::abs(neg)>std::abs(priorNegative[channel]))priorNegative[channel]=neg;
  }
  if(pos>.75*priorPositive[channel]){
   out.positive=pos;out.positiveTolerance=rightTolerance*(edges[rr]-edges[rl]);
   if(pos>priorPositive[channel])priorPositive[channel]=pos;
  }
  if(.05*std::abs(priorNegative[channel])>rms)priorNegative[channel]*=rmsRatio;
  if(.05*priorPositive[channel]>rms)priorPositive[channel]*=rmsRatio;
  if(type2 && secondaryLeft && priorNegative[channel]!=0.){
   out.negative=edges[centerLeft];out.negativeTolerance=leftTolerance*(edges[ll]-edges[lr]);
   if(std::abs(out.negative)>std::abs(priorNegative[channel]))priorNegative[channel]=out.negative;
  }
  if(type2 && secondaryRight && priorPositive[channel]>0.){
   out.positive=edges[centerRight];out.positiveTolerance=rightTolerance*(edges[rr]-edges[rl]);
   if(out.positive>priorPositive[channel])priorPositive[channel]=out.positive;
  }
  return out;
 }
private:
 int offsetTable(int width)const noexcept {
  width=std::clamp(width,1,search-1);
  if(width<a)return b;
  return b+(c-b)*(width-a)/(search-a);
 }
 template<size_t N> static double table(double x,const std::array<int,N>&points,const std::array<double,N>&values)noexcept{
  x=std::max(double(points[0]),std::min(double(points[N-1]-1),x));
  for(size_t i=0;i+1<N;++i)if(x>=points[i] && x<points[i+1])return values[i]+(x-points[i])*(values[i+1]-values[i])/(points[i+1]-points[i]);
  return 0.;
 }
 double widthTable(int width)const noexcept {return table(double(width),map1,std::array<double,5>{.5*sampleRate/44100.,.5*sampleRate/44100.,10.*sampleRate/44100.,30.*sampleRate/44100.,80.*sampleRate/44100.});}
 double extentTable(int width)const noexcept {return table(double(width),map2,std::array<double,5>{0.,0.,sampleRate/44100.,2.*sampleRate/44100.,4.*sampleRate/44100.});}
 double ratio=1.,sampleRate=44100.;int bins=6000,smooth=30,search=2250,a=30,b=60,c=90;
 std::array<int,5>map1{},map2{};std::vector<double>edges,hist,temp,before,after;
 std::array<Result,2>results{};std::array<double,2>priorPositive{},priorNegative{},priorRMS{};
};
}
