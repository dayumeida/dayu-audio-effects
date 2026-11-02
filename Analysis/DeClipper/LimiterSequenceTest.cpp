#include "RecoveredLimiter.hpp"
#include <fstream>
#include <iostream>
int main(int argc,char**argv){std::ifstream f(argv[1],std::ios::binary);std::ofstream out(argv[2],std::ios::binary);std::array<std::vector<float>,2>x;for(auto&v:x)v.resize(2503);float*p[2]={x[0].data(),x[1].data()};dayu::declip::RecoveredLimiter lim;lim.prepare(48000);while(f.read(reinterpret_cast<char*>(p[0]),2503*4)){f.read(reinterpret_cast<char*>(p[1]),2503*4);lim.process(p,2,2503);for(auto&v:x)out.write(reinterpret_cast<char*>(v.data()),2503*4);}}
