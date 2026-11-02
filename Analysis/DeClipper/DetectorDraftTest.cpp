#include "RecoveredDetector.hpp"
#include <fstream>
#include <iostream>
#include <iomanip>
int main(int argc,char**argv){std::ifstream f(argv[1],std::ios::binary|std::ios::ate);size_t n=size_t(f.tellg())/8;f.seekg(0);std::vector<double>x(n);f.read(reinterpret_cast<char*>(x.data()),n*8);dayu::declip::RecoveredDetector d;d.prepare(48000);auto s=d.process(x.data(),int(n),0,argc>2);std::cout<<std::setprecision(17)<<"{\"positive\":"<<s.positive<<",\"negative\":"<<s.negative<<",\"posTolerance\":"<<s.positiveTolerance<<",\"negTolerance\":"<<s.negativeTolerance<<",\"rms\":"<<s.rms<<",\"extent\":"<<s.extent<<"}\n";}
