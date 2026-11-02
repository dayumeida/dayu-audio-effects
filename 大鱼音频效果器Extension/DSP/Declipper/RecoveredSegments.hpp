#pragma once
// Reachable segmentation path of ERA5 De-Clipper 5.4.00 arm64.
// Original flags +0x70/+0x71 are zero for both exposed Processing Types and Quality settings.
// Evidence func-3a234.asm (zero-flag path), func-3af44.asm, func-3ad90.asm.
#include "RecoveredDetector.hpp"
namespace dayu::declip {
struct Region{int status=1,start=0,end=0;};
class RecoveredSegments {
public:
 void prepare(int window,int hop,int maximum){n=window;h=hop;maxRegion=maximum;regions.resize(size_t(n)*2+8);candidates.resize(size_t(h)+1);reset();}
 void reset()noexcept {used=0;candidateUsed=0;activity=0.;}
 int count()const noexcept{return used;}
 const Region* data()const noexcept{return regions.data();}
 double repairedFraction()const noexcept{return activity;}
 void process(const double* x,const RecoveredDetector::Result& d,bool type2)noexcept{
  used=0;candidateUsed=0;scale=type2?.8:1.;
  for(int i=n-h;i<n;++i){
   if(x[i]>=d.positive*scale || x[i]<=d.negative*scale){
    if(candidateUsed>0 && i-candidates[candidateUsed-1].second<2)candidates[candidateUsed-1].second=i;
    else if(candidateUsed<int(candidates.size()))candidates[candidateUsed++]={i,i};
   }
  }
  for(int r=0;r<candidateUsed;++r){
   const int begin=candidates[r].first,end=candidates[r].second;
   for(int at=begin;at<=end;++at){
    // The active zero-flag branch tests a fixed neighbourhood on either side.
    // Assembly's completion comparisons make its inner expansion loop finish
    // after this left/right pair for nonnegative extent.
    const int lo=at-d.extent-1,hi=at+d.extent+1;
    if(lo<n-h || hi>=n)continue;
    validate(x,d,lo,at);validate(x,d,hi,at);
   }
  }
  splitLast();double total=0.;for(int i=0;i<used;++i)total+=regions[i].end-regions[i].start+1;activity=total/h;
 }
private:
 bool validate(const double*x,const RecoveredDetector::Result&d,int first,int second)noexcept{
  if(first<0||first>=n||second<0||second>=n)return false;
  const double v=x[first];const double tolerance=std::abs(v<0.?d.negativeTolerance:d.positiveTolerance);
  const int lo=std::min(first,second),hi=std::max(first,second);double changes=0.;
  for(int i=lo;i<hi;++i)changes+=std::abs(x[i+1]-x[i]);
  const double slope=hi>lo&&changes>0.?changes/(hi-lo):0.;if(slope>tolerance)return false;
  if(v<d.positive*scale && v>d.negative*scale)return false;
  double sum=0.;for(int i=lo;i<=hi;++i)sum+=x[i];const double mean=sum/double(hi-lo+1);
  if(!(std::abs(v-mean)<tolerance))return false;
  if(used>0 && lo<=regions[used-1].end+1){if(hi>regions[used-1].end)regions[used-1].end=std::min(hi,n-1);return true;}
  splitLast();append(std::max(lo,n-h),std::min(hi,n-1));return true;
 }
 void append(int lo,int hi)noexcept{if(used<int(regions.size()))regions[used++]={1,lo,hi};}
 void splitLast()noexcept{
  while(used>0 && regions[used-1].end>=regions[used-1].start+maxRegion){const int cut=regions[used-1].start+maxRegion,end=regions[used-1].end;regions[used-1].end=cut-1;append(cut,end);}
 }
 int n=0,h=1,maxRegion=400,used=0,candidateUsed=0;double scale=1.,activity=0.;
 std::vector<Region>regions;std::vector<std::pair<int,int>>candidates;
};
}
