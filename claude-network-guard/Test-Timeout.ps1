$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Net.Http
$tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Probe.ps1'),[ref]$tokens,[ref]$errors);if($errors){throw ($errors|Out-String)};$source=$ast.Find({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Fetch'},$true).Extent.Text;. ([scriptblock]::Create($source))
function Write-Event($Kind,$Message){}
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public class TimeoutFixture : IDisposable {
 readonly TcpListener listener;
 readonly string mode;
 public int Count;
 public int Port;
 public TimeoutFixture(string mode){
  this.mode=mode;
  listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
  Port=((IPEndPoint)listener.LocalEndpoint).Port;
  var thread=new Thread(Accept);thread.IsBackground=true;thread.Start();
 }
 void Accept(){try{while(true){var client=listener.AcceptTcpClient();ThreadPool.QueueUserWorkItem(Respond,client);}}catch(SocketException){}catch(ObjectDisposedException){}}
 void Respond(object state){using(var client=(TcpClient)state){try{
  var stream=client.GetStream();stream.ReadTimeout=3000;
  byte[] request=new byte[4096];stream.Read(request,0,request.Length);
  int number=Interlocked.Increment(ref Count);
  if(mode=="always"||(mode=="first"&&number==1))Thread.Sleep(1500);
  string body=mode=="wrong"?"{\"ip\":\"192.0.2.2\"}":"{\"ip\":\"192.0.2.1\"}";
  string status=mode=="error"?"500 Internal Server Error":"200 OK";
  byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+"\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n\r\n"+body);
  stream.Write(response,0,response.Length);
 }catch(System.IO.IOException){}}}
 public void Dispose(){listener.Stop();}
}
'@
foreach($mode in @('first','always','wrong','error')){
 $server=[TimeoutFixture]::new($mode)
 try{
  $failed=$false;$result=$null
  try{$result=Fetch ('http://127.0.0.1:'+$server.Port+'/') '' 1}catch{$failed=$true}
  switch($mode){
   first {if($failed -or $server.Count -ne 2 -or $result.ip -ne '192.0.2.1'){throw 'Retry did not recover'}}
   always {if(-not $failed -or $server.Count -ne 2){throw 'Persistent timeout not rejected'}}
   wrong {if($failed -or $server.Count -ne 1 -or $result.ip -eq '192.0.2.1'){throw 'Wrong exit not preserved for validation'}}
   error {if(-not $failed -or $server.Count -ne 1){throw 'HTTP error handling changed'}}
  }
  Write-Output "PASS $mode"
 }finally{$server.Dispose()}
}
