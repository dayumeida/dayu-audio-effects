#include "RecoveredSegments.hpp"
#include <fstream>
#include <iostream>
int main(int argc,char**argv){std::ifstream f(argv[1],std::ios::binary);std::vector<double>x(5224);dayu::declip::RecoveredDetector d;d.prepare(48000);dayu::declip::RecoveredSegments s;s.prepare(5224,2503,435);while(f.read(reinterpret_cast<char*>(x.data()),x.size()*8)){auto r=d.process(x.data(),int(x.size()),0,argc>2);s.process(x.data(),r,argc>2);std::cout<<'[';for(int i=0;i<s.count();++i){if(i)std::cout<<',';auto c=s.data()[i];std::cout<<'['<<c.status<<','<<c.start<<','<<c.end<<']';}std::cout<<"]\n";}}
