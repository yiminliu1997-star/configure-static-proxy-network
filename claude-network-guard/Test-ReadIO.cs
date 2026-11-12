using System;
using System.IO;
using System.Threading;
using System.Diagnostics;

static class ReadTests {
 static void Require(bool condition,string message){if(!condition)throw new Exception(message);}
 static void ExpectReadFailure(string path,int expectedCode){
  var timer=Stopwatch.StartNew();
  try{Data.Read(path);throw new Exception("Read unexpectedly succeeded");}
  catch(IOException error){Require((error.HResult&65535)==expectedCode,"Unexpected I/O error");}
  Require(timer.Elapsed.TotalSeconds<3,"Retry limit exceeded");
 }
 public static int Main(string[] args){
  try{
   string path=Path.Combine(args[0],"native-read.json");
   Data.Write(path,new{Value=1});
   var handle=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None);
   var release=new Thread(delegate(){Thread.Sleep(200);handle.Dispose();});
   release.Start();
   Require(Convert.ToInt32(Data.Read(path)["Value"])==1,"Transient read failed");
   release.Join();
   using(var locked=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None)){ExpectReadFailure(path,32);}
   ExpectReadFailure(path+".missing",2);
   File.WriteAllText(path,"{invalid");
   bool rejected=false;
   try{Data.Read(path);}catch(ArgumentException){rejected=true;}
   Require(rejected,"Malformed JSON accepted");
   Data.Write(path,new{Value=0});
   Exception writerError=null;
   var writer=new Thread(delegate(){try{for(int i=0;i<1000;i++)Data.Write(path,new{Value=i});}catch(Exception error){writerError=error;}});
   writer.Start();
   int reads=0;
   while(writer.IsAlive){Data.Read(path);reads++;}
   writer.Join();
   Require(writerError==null&&reads>0,"Concurrent read/write failed");
   Console.WriteLine("PASS: transient lock, persistent lock, missing file, malformed JSON, concurrent replacement ("+reads+" reads)");
   return 0;
  }catch(Exception error){Console.Error.WriteLine(error);return 1;}
 }
}
