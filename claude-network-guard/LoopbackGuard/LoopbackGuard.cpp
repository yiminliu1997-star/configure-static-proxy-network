#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <fwpmu.h>
#include <rpc.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <sstream>
#include <codecvt>
#include <locale>
#pragma comment(lib,"fwpuclnt.lib")
#pragma comment(lib,"rpcrt4.lib")
#pragma comment(lib,"ws2_32.lib")
// Dedicated namespace. No existing firewall objects are edited.
static const GUID SUB={0x4e45f892,0x244e,0x458f,{0xa5,0xd2,0x68,0x89,0x42,0x45,0x17,0x39}};
static unsigned serial=0;static bool auditing=false;
static void ok(DWORD e){if(e)throw std::runtime_error("WFP error="+std::to_string(e));}
static bool sameValue(const FWP_CONDITION_VALUE0& a,const FWP_CONDITION_VALUE0& b){
 if(a.type!=b.type)return false;switch(a.type){case FWP_UINT8:return a.uint8==b.uint8;case FWP_UINT16:return a.uint16==b.uint16;case FWP_UINT32:return a.uint32==b.uint32;
 case FWP_BYTE_BLOB_TYPE:return a.byteBlob&&b.byteBlob&&a.byteBlob->size==b.byteBlob->size&&!memcmp(a.byteBlob->data,b.byteBlob->data,a.byteBlob->size);
 case FWP_RANGE_TYPE:return a.rangeValue&&b.rangeValue&&a.rangeValue->valueLow.type==FWP_UINT16&&a.rangeValue->valueHigh.type==FWP_UINT16&&a.rangeValue->valueLow.uint16==b.rangeValue->valueLow.uint16&&a.rangeValue->valueHigh.uint16==b.rangeValue->valueHigh.uint16;
 default:return false;}
}
static void emit(HANDLE h,FWPM_FILTER0& f){
 f.filterKey=SUB;f.filterKey.Data1+=++serial;
 if(!auditing){ok(FwpmFilterAdd0(h,&f,nullptr,nullptr));return;}
 FWPM_FILTER0* actual=nullptr;ok(FwpmFilterGetByKey0(h,&f.filterKey,&actual));
 bool valid=actual->layerKey==f.layerKey&&actual->subLayerKey==SUB&&actual->action.type==FWP_ACTION_BLOCK&&(actual->flags&~FWPM_FILTER_FLAG_INDEXED)==f.flags&&actual->numFilterConditions==f.numFilterConditions;
 for(unsigned i=0;valid&&i<f.numFilterConditions;i++){auto& a=actual->filterCondition[i];auto& b=f.filterCondition[i];valid=a.fieldKey==b.fieldKey&&a.matchType==b.matchType&&sameValue(a.conditionValue,b.conditionValue);}
 if(!valid){std::cerr<<"Mismatch filter="<<serial<<" flags="<<actual->flags<<" expectedFlags="<<f.flags<<" conditions="<<actual->numFilterConditions<<" expected="<<f.numFilterConditions<<std::endl;for(unsigned i=0;i<actual->numFilterConditions;i++)std::cerr<<"condition="<<i<<" type="<<actual->filterCondition[i].conditionValue.type<<" match="<<actual->filterCondition[i].matchType<<std::endl;}
 FwpmFreeMemory0((void**)&actual);if(!valid)throw std::runtime_error("Installed filter differs from expected policy");
}
struct Engine {HANDLE h=nullptr; Engine(bool dynamic){FWPM_SESSION0 s={};s.flags=dynamic?FWPM_SESSION_FLAG_DYNAMIC:0;ok(FwpmEngineOpen0(nullptr,RPC_C_AUTHN_WINNT,nullptr,&s,&h));} ~Engine(){if(h)FwpmEngineClose0(h);}};
static void sublayer(HANDLE h,bool persistent){FWPM_SUBLAYER0 s={};s.subLayerKey=SUB;s.displayData.name=(wchar_t*)L"Claude Loopback Port Guard";s.weight=0x8000;s.flags=persistent?FWPM_SUBLAYER_FLAG_PERSISTENT:0;ok(FwpmSubLayerAdd0(h,&s,nullptr));}
static void filters(HANDLE h,const std::wstring& path,std::vector<unsigned short> ports,bool persistent){
 FWP_BYTE_BLOB* app=nullptr;ok(FwpmGetAppIdFromFileName0(path.c_str(),&app));
 try{
 std::sort(ports.begin(),ports.end());ports.erase(std::unique(ports.begin(),ports.end()),ports.end());
 for(const GUID layer:{FWPM_LAYER_ALE_AUTH_CONNECT_V4,FWPM_LAYER_ALE_AUTH_CONNECT_V6}){
  FWPM_FILTER_CONDITION0 c[4]={};c[0].fieldKey=FWPM_CONDITION_ALE_APP_ID;c[0].matchType=FWP_MATCH_EQUAL;c[0].conditionValue.type=FWP_BYTE_BLOB_TYPE;c[0].conditionValue.byteBlob=app;
  c[1].fieldKey=FWPM_CONDITION_FLAGS;c[1].matchType=FWP_MATCH_FLAGS_ALL_SET;c[1].conditionValue.type=FWP_UINT32;c[1].conditionValue.uint32=FWP_CONDITION_FLAG_IS_LOOPBACK;
  c[2].fieldKey=FWPM_CONDITION_IP_PROTOCOL;c[2].conditionValue.type=FWP_UINT8;c[2].conditionValue.uint8=IPPROTO_TCP;
  FWPM_FILTER0 f={};f.displayData.name=(wchar_t*)L"Claude Loopback Port Guard block";f.displayData.description=(wchar_t*)path.c_str();f.layerKey=layer;f.subLayerKey=SUB;f.action.type=FWP_ACTION_BLOCK;f.weight.type=FWP_UINT8;f.weight.uint8=15;f.flags=persistent?FWPM_FILTER_FLAG_PERSISTENT:0;f.filterCondition=c;
  // Production proxies listen only on 127.0.0.1. Do not permit the same
  // port on ::1 or another 127/8 address owned by an unrelated service.
  if(layer==FWPM_LAYER_ALE_AUTH_CONNECT_V6){f.numFilterConditions=2;emit(h,f);continue;}
  c[2].fieldKey=FWPM_CONDITION_IP_REMOTE_ADDRESS;c[2].matchType=FWP_MATCH_NOT_EQUAL;c[2].conditionValue.type=FWP_UINT32;c[2].conditionValue.uint32=0x7f000001;f.numFilterConditions=3;emit(h,f);
  c[2].fieldKey=FWPM_CONDITION_IP_PROTOCOL;c[2].conditionValue.type=FWP_UINT8;c[2].conditionValue.uint8=IPPROTO_TCP;
  c[2].matchType=FWP_MATCH_NOT_EQUAL;f.numFilterConditions=3;emit(h,f);
  c[2].matchType=FWP_MATCH_EQUAL;c[3].fieldKey=FWPM_CONDITION_IP_REMOTE_PORT;c[3].matchType=FWP_MATCH_RANGE;c[3].conditionValue.type=FWP_RANGE_TYPE;
  FWP_RANGE0 range={};range.valueLow.type=FWP_UINT16;range.valueHigh.type=FWP_UINT16;c[3].conditionValue.rangeValue=&range;f.numFilterConditions=4;
  unsigned int lo=0;ports.push_back(65535);
  for(size_t i=0;i<ports.size();i++){unsigned int end=ports[i];bool sentinel=i==ports.size()-1;unsigned int hi=sentinel?65535:end-1;
   if(lo<=hi){range.valueLow.uint16=(UINT16)lo;range.valueHigh.uint16=(UINT16)hi;emit(h,f);}lo=end+1;
  }ports.pop_back();
 }
 }catch(...){FwpmFreeMemory0((void**)&app);throw;}FwpmFreeMemory0((void**)&app);
}
static SOCKET listener(int af,int type,unsigned short& port,const char* address=nullptr){SOCKET s=socket(af,type,type==SOCK_STREAM?IPPROTO_TCP:IPPROTO_UDP);if(s==INVALID_SOCKET)throw std::runtime_error("socket");sockaddr_storage ss={};int n;
 if(af==AF_INET){auto a=(sockaddr_in*)&ss;a->sin_family=AF_INET;a->sin_port=htons(port);inet_pton(AF_INET,address?address:"127.0.0.1",&a->sin_addr);n=sizeof(*a);}else{auto a=(sockaddr_in6*)&ss;a->sin6_family=AF_INET6;a->sin6_port=htons(port);a->sin6_addr=in6addr_loopback;n=sizeof(*a);}
 if(bind(s,(sockaddr*)&ss,n))throw std::runtime_error("bind");if(type==SOCK_STREAM&&listen(s,8))throw std::runtime_error("listen");getsockname(s,(sockaddr*)&ss,&n);port=ntohs(af==AF_INET?((sockaddr_in*)&ss)->sin_port:((sockaddr_in6*)&ss)->sin6_port);return s;
}
static bool delivered(int af,int type,unsigned short port,SOCKET server,const char* address=nullptr){
 SOCKET s=socket(af,type,type==SOCK_STREAM?IPPROTO_TCP:IPPROTO_UDP);u_long nonblock=1;ioctlsocket(s,FIONBIO,&nonblock);sockaddr_storage ss={};int n;
 if(af==AF_INET){auto a=(sockaddr_in*)&ss;a->sin_family=AF_INET;a->sin_port=htons(port);inet_pton(AF_INET,address?address:"127.0.0.1",&a->sin_addr);n=sizeof(*a);}else{auto a=(sockaddr_in6*)&ss;a->sin6_family=AF_INET6;a->sin6_port=htons(port);inet_pton(AF_INET6,address?address:"::1",&a->sin6_addr);n=sizeof(*a);}
 int r=type==SOCK_STREAM?connect(s,(sockaddr*)&ss,n):sendto(s,"x",1,0,(sockaddr*)&ss,n);int error=r==SOCKET_ERROR?WSAGetLastError():0;
 fd_set set;FD_ZERO(&set);FD_SET(server,&set);timeval timeout={0,350000};bool received=select(0,&set,nullptr,nullptr,&timeout)>0;
 if(received){if(type==SOCK_STREAM){SOCKET a=accept(server,nullptr,nullptr);u_long blocking=0;ioctlsocket(s,FIONBIO,&blocking);DWORD ms=500;setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,(char*)&ms,sizeof(ms));setsockopt(a,SOL_SOCKET,SO_RCVTIMEO,(char*)&ms,sizeof(ms));char b=0;bool echo=send(s,"q",1,0)==1&&recv(a,&b,1,0)==1&&b=='q'&&send(a,"r",1,0)==1&&recv(s,&b,1,0)==1&&b=='r';received=echo;closesocket(a);}else{char b[16];recv(server,b,sizeof(b),0);}}
 closesocket(s);std::cout<<" error="<<error;return received;
}
static std::vector<GUID> owned(HANDLE h);
static int selftest(const std::wstring& path,bool persistent=false){
 WSADATA ws;WSAStartup(MAKEWORD(2,2),&ws);unsigned short ports[8]={};SOCKET servers[8];int afs[]={AF_INET,AF_INET,AF_INET6,AF_INET6,AF_INET,AF_INET6,AF_INET,AF_INET};int types[]={SOCK_STREAM,SOCK_STREAM,SOCK_STREAM,SOCK_STREAM,SOCK_DGRAM,SOCK_DGRAM,SOCK_STREAM,SOCK_STREAM};
 for(int i=0;i<8;i++){if(i==7)ports[i]=ports[0];servers[i]=listener(afs[i],types[i],ports[i],i==7?"127.0.0.2":nullptr);}
 int failed=0;for(int stage=0;stage<3;stage++){
  Engine* engine=nullptr;if(stage==1){serial=0;engine=new Engine(!persistent);sublayer(engine->h,persistent);filters(engine->h,path,{ports[0],ports[6]},persistent);if(persistent){delete engine;engine=new Engine(false);serial=0;auditing=true;filters(engine->h,path,{ports[0],ports[6]},true);auditing=false;std::cout<<"PASS persistent filters survived installer exit; audit exact match"<<std::endl;}}
  for(int i=0;i<8;i++){bool expected=stage!=1||i==0||i==6;std::cout<<"stage="<<stage<<" family="<<afs[i]<<" type="<<types[i]<<" port="<<ports[i];bool actual=delivered(afs[i],types[i],ports[i],servers[i],i==7?"127.0.0.2":nullptr);std::cout<<" received="<<actual<<" expected="<<expected<<std::endl;if(actual!=expected)failed++;}
  if(engine&&persistent){auto keys=owned(engine->h);ok(FwpmFilterDeleteByKey0(engine->h,&keys[0]));serial=0;auditing=true;bool detected=false;try{filters(engine->h,path,{ports[0],ports[6]},true);}catch(...){detected=true;}auditing=false;if(!detected)failed++;std::cout<<"MissingFilterDetected="<<detected<<std::endl;for(size_t k=1;k<keys.size();k++)ok(FwpmFilterDeleteByKey0(engine->h,&keys[k]));ok(FwpmSubLayerDeleteByKey0(engine->h,&SUB));}
  delete engine;
 }
 for(auto s:servers)closesocket(s);WSACleanup();std::cout<<"FAILURES="<<failed<<std::endl;return failed?1:0;
}
static std::vector<GUID> owned(HANDLE h){HANDLE e=nullptr;ok(FwpmFilterCreateEnumHandle0(h,nullptr,&e));std::vector<GUID> keys;try{while(true){FWPM_FILTER0** list=nullptr;UINT32 count=0;ok(FwpmFilterEnum0(h,e,256,&list,&count));for(UINT32 i=0;i<count;i++)if(list[i]->subLayerKey==SUB)keys.push_back(list[i]->filterKey);FwpmFreeMemory0((void**)&list);if(count<256)break;}}catch(...){FwpmFilterDestroyEnumHandle0(h,e);throw;}FwpmFilterDestroyEnumHandle0(h,e);return keys;}
static int manage(const std::wstring& action,const wchar_t* manifest){Engine e(false);bool transaction=action!=L"audit";if(transaction)ok(FwpmTransactionBegin0(e.h,0));try{
 if(action==L"remove"){for(auto key:owned(e.h))ok(FwpmFilterDeleteByKey0(e.h,&key));ok(FwpmSubLayerDeleteByKey0(e.h,&SUB));}
 else{
  if(action==L"install")sublayer(e.h,true);else if(action!=L"audit")throw std::runtime_error("Unknown action");
  auditing=action==L"audit";serial=0;
  std::wifstream in(manifest);in.imbue(std::locale(in.getloc(),new std::codecvt_utf8<wchar_t>));if(!in)throw std::runtime_error("Cannot open manifest");std::wstring line;int targets=0;
  while(std::getline(in,line)){if(line.empty())continue;if(line.back()==L'\r')line.pop_back();auto tab=line.find(L'\t');if(tab==std::wstring::npos)throw std::runtime_error("Invalid manifest");std::wstring path=line.substr(0,tab);std::wistringstream values(line.substr(tab+1));std::wstring value;std::vector<unsigned short> ports;
   while(std::getline(values,value,L',')){size_t pos=0;int port=std::stoi(value,&pos);if(pos!=value.size()||port<1||port>=65535)throw std::runtime_error("Invalid port");ports.push_back((unsigned short)port);}if(ports.empty())throw std::runtime_error("No allowed port");filters(e.h,path,ports,true);targets++;
  }if(!targets)throw std::runtime_error("Empty manifest");if(auditing&&owned(e.h).size()!=serial)throw std::runtime_error("Unexpected filter count");std::cout<<"TARGETS="<<targets<<" FILTERS="<<serial<<std::endl;
 }
 if(transaction)ok(FwpmTransactionCommit0(e.h));std::cout<<"OK"<<std::endl;return 0;
 }catch(...){if(transaction)FwpmTransactionAbort0(e.h);throw;}}
int wmain(int argc,wchar_t** argv){try{wchar_t path[32768];GetModuleFileNameW(nullptr,path,32768);if(argc==2&&std::wstring(argv[1])==L"selftest")return selftest(path);if(argc==2&&std::wstring(argv[1])==L"selftest-persistent")return selftest(path,true);if(argc==3)return manage(argv[1],argv[2]);std::cerr<<"Usage: LoopbackGuard selftest | install/audit/remove manifest"<<std::endl;return 2;}catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 3;}}
