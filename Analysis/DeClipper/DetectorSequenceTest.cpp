#include "RecoveredDetector.hpp"
#include <fstream>
#include <iostream>
#include <iomanip>
int main(int argc,char**argv){std::ifstream f(argv[1],std::ios::binary);std::vector<double>x(5224);dayu::declip::RecoveredDetector d;d.prepare(48000);while(f.read(reinterpret_cast<char*>(x.data()),x.size()*8)){auto s=d.process(x.data(),int(x.size()),0,argc>2);std::cout<<std::setprecision(17)<<'['<<s.positive<<','<<s.negative<<','<<s.positiveTolerance<<','<<s.negativeTolerance<<','<<s.rms<<','<<s.extent<<"]\n";}}
