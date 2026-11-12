using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Threading;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Drawing;
using System.Runtime.InteropServices;

static class Data {
 public static readonly string Root=AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
 public static readonly string State=Path.Combine(Root,"state");
 static JavaScriptSerializer Serializer(){return new JavaScriptSerializer{MaxJsonLength=2097152};}
 public static Dictionary<string,object> Read(string path){
  for(int attempt=0;;attempt++){
   try{
    using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
    using(var reader=new StreamReader(stream,Encoding.UTF8)){
     return (Dictionary<string,object>)Serializer().DeserializeObject(reader.ReadToEnd());
    }
   }catch(IOException error){
    int code=error.HResult&65535;
    if((code!=2&&code!=32&&code!=33)||attempt>=20)throw;
    Thread.Sleep(50);
   }
  }
 }
 public static string Text(IDictionary<string,object> d,string k){object v;return d!=null&&d.TryGetValue(k,out v)&&v!=null?Convert.ToString(v):"";}
 public static bool Flag(IDictionary<string,object> d,string k){object v;return d!=null&&d.TryGetValue(k,out v)&&v is bool&&(bool)v;}
 public static bool Fresh(IDictionary<string,object> d,int seconds){DateTime t;if(!DateTime.TryParse(Text(d,"At"),null,System.Globalization.DateTimeStyles.RoundtripKind,out t))return false;double age=(DateTime.UtcNow-t.ToUniversalTime()).TotalSeconds;return age>=-5&&age<=seconds;}
 public static string Json(object value){return Serializer().Serialize(value);}
 public static void Write(string path,object value){
  string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
  File.WriteAllText(temp,Json(value),new UTF8Encoding(false));
  try{for(int i=0;;i++)try{
   if(File.Exists(path)){string backup=path+"."+Guid.NewGuid().ToString("N")+".bak";File.Replace(temp,path,backup);try{File.Delete(backup);}catch{}}
   else File.Move(temp,path);return;
  }catch(IOException e){int code=e.HResult&65535;if((code!=32&&code!=33)||i>=20)throw;Thread.Sleep(50);}}
  finally{if(File.Exists(temp))try{File.Delete(temp);}catch{}}
 }
 public static void Log(string kind,string message){string p=Path.Combine(State,"events-"+Process.GetCurrentProcess().Id+".jsonl");if(File.Exists(p)&&new FileInfo(p).Length>2097152){if(File.Exists(p+".previous"))File.Delete(p+".previous");File.Move(p,p+".previous");}File.AppendAllText(p,Json(new{At=DateTime.UtcNow.ToString("o"),Kind=kind,Message=message})+Environment.NewLine,Encoding.UTF8);}
 public static bool Armed {get{return File.Exists(Path.Combine(State,"armed"));}}
 public static void Lock(string reason){
  string path=Path.Combine(State,"lock.json");if(File.Exists(path))return;
  try{using(var f=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read)){byte[] b=Encoding.UTF8.GetBytes(Json(new{At=DateTime.UtcNow.ToString("o"),Reason=reason}));f.Write(b,0,b.Length);}}
  catch(IOException){if(!File.Exists(path))throw;return;}Log("locked",reason);
 }
}

static class Watch {
 public static bool Target(string name,string path,IDictionary<string,object> cfg){
  if(String.IsNullOrEmpty(path))return false;
  if(System.Text.RegularExpressions.Regex.IsMatch(path,@"^C:\\Program Files\\WindowsApps\\Claude_[^\\]+\\app\\(?:[^\\]+\\)*[^\\]+\.exe$",System.Text.RegularExpressions.RegexOptions.IgnoreCase))return true;
  if(name.Equals("node",StringComparison.OrdinalIgnoreCase))return path.Equals(Data.Text(cfg,"DedicatedNode"),StringComparison.OrdinalIgnoreCase);
  if(!name.Equals("claude",StringComparison.OrdinalIgnoreCase))return false;
  string prefix=@"C:\Program Files\WindowsApps\Claude_",suffix=@"\app\claude.exe";
  bool desktop=path.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)&&path.EndsWith(suffix,StringComparison.OrdinalIgnoreCase)&&path.Length>prefix.Length+suffix.Length&&path.Substring(prefix.Length,path.Length-prefix.Length-suffix.Length).IndexOf('\\')<0;
  return desktop||path.StartsWith(Data.Text(cfg,"CodeRoot").TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase);
 }
 public static bool KillExact(int id,string path){using(var p=Process.GetProcessById(id)){if(!String.Equals(p.MainModule.FileName,path,StringComparison.OrdinalIgnoreCase))return false;p.Kill();return true;}}
 public static void Stop(IDictionary<string,object> cfg){foreach(var p in Process.GetProcesses())using(p){string name="unknown";try{name=p.ProcessName;string path=p.MainModule.FileName;if(Target(name,path,cfg)&&KillExact(p.Id,path))Data.Log("terminated",name+" PID "+p.Id);}catch(Exception e){if(name=="claude"||name=="cowork-svc"||name.StartsWith("claude-ssh-")||name=="github-mcp-server")Data.Log("termination-error",name+" PID "+p.Id+": "+e.Message);}}}
 static void StartGuard(IDictionary<string,object> cfg){
  object service=null,folder=null,task=null;
  try{service=Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service"));dynamic s=service;s.Connect();folder=s.GetFolder("\\");dynamic f=folder;task=f.GetTask(Data.Text(cfg,"GuardTask"));dynamic t=task;if((int)t.State!=4)t.Run(null);}
  finally{foreach(object o in new[]{task,folder,service})if(o!=null&&Marshal.IsComObject(o))Marshal.FinalReleaseComObject(o);}
 }
 public static void Run(){
  using(var mutex=new Mutex(false,"Global\\ClaudeNetworkGuard-Supervisor-v1")){bool own=false;try{own=mutex.WaitOne(1500);}catch(AbandonedMutexException){own=true;}if(!own){Data.Log("startup-busy","Supervisor mutex still owned");return;}
   var cfg=Data.Read(Path.Combine(Data.Root,"config.json"));int pid=Process.GetCurrentProcess().Id;int session=Process.GetCurrentProcess().SessionId;
   Data.Log("started","Native lightweight supervisor started");
   while(true){try{
    Dictionary<string,object> status=null;try{status=Data.Read(Path.Combine(Data.State,"status.json"));}catch{}
    bool stale=!Data.Fresh(status,10);
    if(stale&&Data.Armed){Data.Lock("Monitor heartbeat missing/stale (10s)");Stop(cfg);}
    if(stale)StartGuard(cfg);
    Data.Write(Path.Combine(Data.State,"supervisor.json"),new{At=DateTime.UtcNow.ToString("o"),Pid=pid,SessionId=session,GuardStale=stale,Implementation="native-v2"});
   }catch(Exception e){try{Data.Log("supervisor-error",e.Message);}catch{}if(Data.Armed){try{Data.Lock("Supervisor check failed");Stop(cfg);}catch{}}}
   Thread.Sleep(1000);
   }
  }
 }
}

class Dashboard:Form {
 Label mode=new Label(),info=new Label(),reason=new Label();DataGridView grid=new DataGridView();Button stop=new Button(),unlock=new Button();NotifyIcon tray=new NotifyIcon();System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();string lastMode="",lastReport="",preview;
 public Dashboard(string previewFile){
  preview=previewFile;Text="Claude 网络守护 v1.0";ClientSize=new Size(1000,660);MinimumSize=new Size(850,570);StartPosition=FormStartPosition.CenterScreen;BackColor=Color.FromArgb(243,245,248);Font=new Font("Microsoft YaHei UI",10);
  var layout=new TableLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(24),ColumnCount=1,RowCount=6};
  layout.RowStyles.Add(new RowStyle(SizeType.Absolute,54));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,116));layout.RowStyles.Add(new RowStyle(SizeType.Percent,100));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,56));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,60));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,0));Controls.Add(layout);
  var title=new Label{Text="Claude 网络守护",Font=new Font(Font.FontFamily,23,FontStyle.Bold),Dock=DockStyle.Fill,ForeColor=Color.FromArgb(20,35,58)};layout.Controls.Add(title,0,0);
  var card=new TableLayoutPanel{Dock=DockStyle.Fill,BackColor=Color.White,Padding=new Padding(16),RowCount=3,ColumnCount=1,Margin=new Padding(0,0,0,12)};
  card.RowStyles.Add(new RowStyle(SizeType.Absolute,30));card.RowStyles.Add(new RowStyle(SizeType.Absolute,23));card.RowStyles.Add(new RowStyle(SizeType.Percent,100));mode.Font=new Font(Font.FontFamily,17,FontStyle.Bold);mode.Text="读取后台状态…";mode.Dock=info.Dock=reason.Dock=DockStyle.Fill;reason.ForeColor=Color.Maroon;card.Controls.Add(mode,0,0);card.Controls.Add(info,0,1);card.Controls.Add(reason,0,2);layout.Controls.Add(card,0,1);
  grid.Dock=DockStyle.Fill;grid.ReadOnly=true;grid.AllowUserToAddRows=false;grid.AllowUserToDeleteRows=false;grid.RowHeadersVisible=false;grid.BackgroundColor=Color.White;grid.BorderStyle=BorderStyle.None;grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect;grid.MultiSelect=false;grid.AlternatingRowsDefaultCellStyle.BackColor=Color.FromArgb(246,248,250);
  grid.Columns.Add("Name","检查项目");grid.Columns.Add("Result","结果");grid.Columns.Add("Detail","说明");grid.Columns[0].FillWeight=45;grid.Columns[1].FillWeight=12;grid.Columns[2].FillWeight=43;layout.Controls.Add(grid,0,2);
  var buttons=new FlowLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(0,10,0,0)};
  Button check=new Button{Text="立即检查",AutoSize=true,Height=35};stop.Text="立即锁定并停止 Claude";stop.AutoSize=true;stop.Height=35;stop.BackColor=Color.FromArgb(163,39,50);stop.ForeColor=Color.White;unlock.Text="检查通过后手动解锁";unlock.AutoSize=true;unlock.Height=35;var logs=new Button{Text="查看报告与日志",AutoSize=true,Height=35};buttons.Controls.AddRange(new Control[]{check,stop,unlock,logs});layout.Controls.Add(buttons,0,3);
  layout.Controls.Add(new Label{Dock=DockStyle.Fill,Text="关闭窗口不停止后台保护。出口检测异常仅提醒，确认出口 IP 不符时锁定。\n存在检测窗口，不是零泄漏保证；锁定会关闭 Claude 并中断任务。Codex、共享代理和 ToDesk 不在停止范围。",ForeColor=Color.DimGray},0,4);
  check.Click+=delegate{Command("check");};stop.Click+=delegate{Command("lock");};unlock.Click+=delegate{Command("unlock");};logs.Click+=delegate{Process.Start("explorer.exe","\""+Data.State+"\"");};
  Icon=new Icon(Path.Combine(Data.Root,"guard-icon.ico"));tray.Icon=Icon;tray.Text="Claude 网络守护 v1.0";tray.Visible=true;tray.DoubleClick+=delegate{Show();WindowState=FormWindowState.Normal;Activate();};
  timer.Interval=2000;timer.Tick+=delegate{RefreshState();};Shown+=delegate{RefreshState();timer.Start();};FormClosed+=delegate{timer.Stop();timer.Dispose();tray.Dispose();};
 }
 void Command(string action){try{Data.Write(Path.Combine(Data.State,"command.json"),new{Action=action,At=DateTime.UtcNow.ToString("o"),Id=Guid.NewGuid().ToString()});reason.Text="请求已提交，等待后台处理。";}catch(Exception e){reason.Text=e.Message;}}
 void RefreshState(){try{
  var s=Data.Read(Path.Combine(Data.State,"status.json"));var sup=Data.Read(Path.Combine(Data.State,"supervisor.json"));var h=Data.Read(Path.Combine(Data.State,"health.json"));string m=Data.Text(s,"Mode");bool warning=false;foreach(object item in (object[])h["Checks"]){if(Data.Text((Dictionary<string,object>)item,"Status")=="warning")warning=true;}if(m=="HEALTHY"&&warning)m="WARNING";if(!Data.Fresh(s,10)||!Data.Fresh(sup,10))m="OFFLINE";
  var labels=new Dictionary<string,string>{{"WARNING","保护已启用 · 出口检测提醒"},{"HEALTHY","保护已启用 · 当前检查正常"},{"OBSERVE","观察模式 · 尚未启用自动停止"},{"LOCKED","已锁定 · 正在停止 Claude"},{"VERIFYING_UNLOCK","解锁核验中 · Claude 仍被停止"},{"ERROR","监控异常 · 请查看记录"},{"CHECKING","检查进行中"},{"OFFLINE","后台心跳失联 · 不能确认保护"}};
  mode.Text=labels.ContainsKey(m)?labels[m]:m;mode.ForeColor=m=="HEALTHY"?Color.SeaGreen:((m=="OBSERVE"||m=="WARNING")?Color.DarkGoldenrod:Color.Maroon);
  object lockObj;s.TryGetValue("Lock",out lockObj);var l=lockObj as Dictionary<string,object>;reason.Text=(l==null?"":"锁定原因："+Data.Text(l,"Reason")+"  ")+Data.Text(s,"Notice");
  string report=Data.Text(h,"At");if(report!=lastReport){int pass=0,fail=0,warn=0;grid.SuspendLayout();grid.Rows.Clear();foreach(object o in (object[])h["Checks"]){var c=(Dictionary<string,object>)o;string status=Data.Text(c,"Status");if(status=="pass")pass++;else if(status=="warning")warn++;else if(status!="quarantined")fail++;grid.Rows.Add(Data.Text(c,"Name"),status=="pass"?"通过":status=="quarantined"?"锁定停用":status=="warning"?"提醒":"异常",Data.Text(c,"Detail"));}grid.ResumeLayout();DateTime t=DateTime.Parse(report,null,System.Globalization.DateTimeStyles.RoundtripKind);info.Text="目标出口 "+Data.Text(h,"ExpectedExit")+"  |  通过 "+pass+"  提醒 "+warn+"  异常 "+fail+"  |  完整检查 "+t.ToLocalTime().ToString("HH:mm:ss");lastReport=report;}
  stop.Enabled=Data.Flag(s,"Armed")&&m!="OFFLINE";unlock.Enabled=m=="LOCKED";
  if(m!=lastMode&&(m=="LOCKED"||m=="ERROR"||m=="OFFLINE"||m=="WARNING"))tray.ShowBalloonTip(8000,"Claude 网络守护",mode.Text,ToolTipIcon.Warning);lastMode=m;
  if(!String.IsNullOrEmpty(preview)&&!File.Exists(preview)){using(var bitmap=new Bitmap(Width,Height)){DrawToBitmap(bitmap,new Rectangle(0,0,Width,Height));bitmap.Save(preview,System.Drawing.Imaging.ImageFormat.Png);}}
 }catch(Exception e){mode.Text="后台尚未就绪";reason.Text=e.Message;}}
}

static class Program {
 [STAThread]static int Main(string[] args){try{
  if(args.Length>0&&args[0]=="--supervisor"){Watch.Run();return 0;}
  if(args.Length>0&&args[0]=="--self-test"){SelfTest();return 0;}
  if(args.Length>0&&args[0]=="--sleep"){Thread.Sleep(60000);return 0;}
  Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new Dashboard(args.Length>1&&args[0]=="--preview"?args[1]:null));return 0;
 }catch(Exception e){File.WriteAllText(Path.Combine(Data.State,"native-error-"+Process.GetCurrentProcess().Id+".log"),e.ToString());return 1;}}
 static void Assert(bool condition,string name){if(!condition)throw new Exception("Test failed: "+name);}
 static void SelfTest(){
  var cfg=Data.Read(Path.Combine(Data.Root,"config.json"));
  Assert(Watch.Target("claude",@"C:\Program Files\WindowsApps\Claude_99_x64\app\claude.exe",cfg),"desktop");
  Assert(Watch.Target("cowork-svc",@"C:\Program Files\WindowsApps\Claude_99_x64\app\resources\cowork-svc.exe",cfg),"cowork");
  Assert(Watch.Target("new-helper",@"C:\Program Files\WindowsApps\Claude_99_x64\app\resources\new-helper.exe",cfg),"future helper");
  Assert(!Watch.Target("cowork-svc",@"C:\other\cowork-svc.exe",cfg),"foreign helper excluded");
  Assert(!Watch.Target("helper",@"C:\Program Files\WindowsApps\Other_99\app\helper.exe",cfg),"foreign package excluded");
  Assert(Watch.Target("claude",Data.Text(cfg,"CodeRoot")+@"\99\claude.exe",cfg),"code");
  Assert(Watch.Target("node",Data.Text(cfg,"DedicatedNode"),cfg),"dedicated node");
  Assert(!Watch.Target("node",@"C:\shared\node.exe",cfg),"shared node excluded");Assert(!Watch.Target("Codex",@"C:\Codex.exe",cfg),"Codex excluded");Assert(!Watch.Target("ToDesk",@"C:\ToDesk.exe",cfg),"ToDesk excluded");
  var d=new Dictionary<string,object>{{"At",DateTime.UtcNow.ToString("o")}};Assert(Data.Fresh(d,10),"fresh");d["At"]=DateTime.UtcNow.AddSeconds(-20).ToString("o");Assert(!Data.Fresh(d,10),"stale");
  string dir=Path.Combine(Data.Root,"native-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);string f=Path.Combine(dir,"test.json");Data.Write(f,new{Value=1});
  using(var handle=new FileStream(f,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)){Data.Write(f,new{Value=2});Assert(Convert.ToInt32(Data.Read(f)["Value"])==2,"atomic shared read");}
  var held=new FileStream(f,FileMode.Open,FileAccess.Read,FileShare.ReadWrite);var t=new Thread(delegate(){Thread.Sleep(300);held.Dispose();});t.Start();Data.Write(f,new{Value=3});t.Join();Assert(Convert.ToInt32(Data.Read(f)["Value"])==3,"retry sharing");
  bool failed=false;using(var locked=new FileStream(f,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)){try{Data.Write(f,new{Value=4});}catch(IOException){failed=true;}}Assert(failed&&Convert.ToInt32(Data.Read(f)["Value"])==3,"permanent error preserved");
  var psi=new ProcessStartInfo(Application.ExecutablePath,"--sleep"){UseShellExecute=false,CreateNoWindow=true};using(var p=Process.Start(psi)){try{Thread.Sleep(300);Assert(Watch.KillExact(p.Id,Application.ExecutablePath),"stop owned dummy");Assert(p.WaitForExit(3000),"dummy exited");}finally{if(!p.HasExited)p.Kill();}}
  Data.Write(Path.Combine(Data.Root,"native-tests.json"),new{At=DateTime.UtcNow.ToString("o"),AllPassed=true,Checks=17,RealClaudeFaultInjected=false});
 }
}
