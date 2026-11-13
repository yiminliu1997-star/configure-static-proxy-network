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

class CheckCard:Panel {
 public int Index {get;private set;} public int Severity {get;private set;} public bool Expanded;
 readonly Button header=new Button(); readonly DataGridView grid=new DataGridView();
 string heading=""; public CheckCard(int index){Index=index;BackColor=Color.White;Margin=new Padding(0,0,0,10);Padding=new Padding(1);Height=78;
  header.Dock=DockStyle.Top;header.Height=74;header.FlatStyle=FlatStyle.Flat;header.FlatAppearance.BorderSize=0;header.TextAlign=ContentAlignment.MiddleLeft;header.Padding=new Padding(18,0,12,0);header.Cursor=Cursors.Hand;header.BackColor=Color.White;
  grid.Dock=DockStyle.Fill;grid.ReadOnly=true;grid.AllowUserToAddRows=false;grid.AllowUserToDeleteRows=false;grid.RowHeadersVisible=false;grid.BackgroundColor=Color.White;grid.BorderStyle=BorderStyle.None;grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect;grid.MultiSelect=false;grid.AutoGenerateColumns=false;grid.AlternatingRowsDefaultCellStyle.BackColor=Color.FromArgb(247,249,252);grid.ColumnHeadersHeight=30;grid.RowTemplate.Height=28;grid.DefaultCellStyle.Font=new Font("Microsoft YaHei UI",9);grid.Columns.Add("Name","检查项目");grid.Columns.Add("Status","结果");grid.Columns.Add("Details","原始名称与详细信息");grid.Columns[0].FillWeight=32;grid.Columns[1].FillWeight=10;grid.Columns[2].FillWeight=58;grid.Visible=false;
  Controls.Add(grid);Controls.Add(header);header.Click+=delegate{SetExpanded(!Expanded);};
 }
 void SetExpanded(bool value){Expanded=value;grid.Visible=value;Height=value?300:78;header.Text=(value?"▾  ":"▸  ")+heading;}
 public void UpdateRows(string title,string description,List<Dictionary<string,object>> rows){int pass=0,warn=0,fail=0,paused=0;grid.Rows.Clear();foreach(var c in rows){string s=Data.Text(c,"Status"),n=Data.Text(c,"Name");if(s=="pass")pass++;else if(s=="warning")warn++;else if(s=="quarantined")paused++;else fail++;int id=grid.Rows.Add(Dashboard.Friendly(n),s=="pass"?"通过":s=="warning"?"提醒":s=="quarantined"?"锁定停用":"异常",n+"  "+Data.Text(c,"Detail"));if(s!="pass")grid.Rows[id].DefaultCellStyle.ForeColor=s=="warning"?Color.DarkGoldenrod:s=="quarantined"?Color.DimGray:Color.Firebrick;}
  int next=fail>0?2:warn>0?1:0;bool open=next>Severity;Severity=next;
  string state=fail>0?"异常 "+fail:warn>0?"提醒 "+warn:paused>0?"部分锁定停用":rows.Count==0?"等待检查":"正常";
  heading=title+"     "+state+"     "+pass+" / "+rows.Count+" 项通过\n       "+description;
  header.ForeColor=fail>0?Color.Firebrick:warn>0?Color.DarkGoldenrod:Color.FromArgb(29,53,76);SetExpanded(open||Expanded);
 }
}

class Dashboard:Form {
 Label mode=new Label(),info=new Label(),reason=new Label();Button stop=new Button(),unlock=new Button();NotifyIcon tray=new NotifyIcon();System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();FlowLayoutPanel cards=new FlowLayoutPanel();CheckCard[] groups=new CheckCard[6];string lastMode="",lastReport="",preview;
 static readonly string[] Titles={"代理与出口","防直连与端口限制","DNS 与 WebRTC","Claude 版本与配置","后台守护","文件与配置完整性"};
 static readonly string[] Descriptions={"主代理、专用路由器与出口 IP","系统防火墙、程序保护与本机端口白名单","DNS 解析保护与浏览器 WebRTC 策略","程序版本覆盖、自动升级与应用代理设置","守护任务与心跳；顶部状态同时核对主监控和独立看守","必需文件、运行组件与保护清单"};
 public static int Category(string name){
  if(name.StartsWith("File:"))return 5;
  if(name.StartsWith("DNS")||name.StartsWith("WebRTC:")||name=="Listener:TCP53"||name.StartsWith("Edge:"))return 2;
  if(name.StartsWith("Firewall:")||name.StartsWith("Loopback:"))return 1;
  if(name.StartsWith("Task:")||name.StartsWith("ProxyGuard:"))return 4;
  if(name.StartsWith("Code:")||name.StartsWith("Desktop:")||name.StartsWith("Codex:")||name.StartsWith("Version coverage:")||name.StartsWith("Running path:")||name=="Desktop package discovery"||name.Contains("auto-update"))return 3;
  if(name.StartsWith("User:")||name.StartsWith("WinINet:")||name.StartsWith("Live:")||name.StartsWith("Listener:"))return 0;
  return 5;
 }
 public static string Friendly(string n){
  var exact=new Dictionary<string,string>{{"Live:static exit","主代理出口 IP"},{"Live:router exit","专用路由器出口 IP"},{"Live:router proxy peer","路由器连接主代理"},{"Firewall:profiles","系统防火墙启用状态"},{"Firewall:target count","受保护程序清单"},{"Loopback: protected path and allowed-port coverage","本机端口白名单覆盖"},{"Loopback: persistent WFP filters intact","本机端口限制完整性"},{"Desktop package discovery","Claude Desktop 安装包发现"},{"Desktop auto-update disabled","Desktop 自动升级已关闭"},{"Code auto-update disabled","Code 自动升级已关闭"},{"ProxyGuard:fresh healthy heartbeat","代理配置守护心跳"},{"DNS query A","IPv4 DNS 实际解析"},{"DNS query AAAA","IPv6 DNS 实际解析"},{"DNS:DoH via local proxy","加密 DNS 经过本机代理"},{"Edge:system DNS and no prediction","Edge DNS 与预加载设置"}};string value;if(exact.TryGetValue(n,out value))return value;
  if(n.StartsWith("WebRTC:")){string browser=n.Contains("Edge")?"Edge":"Chrome";return browser+" · "+(n.Contains("UDP")?"禁止非代理 UDP":n.Contains("overrides")?"网址覆盖限制":"无本地 IP 暴露例外");}
  if(n.StartsWith("Version coverage:"))return "版本规则覆盖 · "+Path.GetFileName(n.Substring(17).Trim());
  if(n.StartsWith("Running path:"))return "运行程序覆盖 · "+Path.GetFileName(n.Substring(13).Trim());
  if(n.StartsWith("File:"))return "必需文件 · "+n.Substring(5);
  if(n.StartsWith("Firewall:"))return "禁止直连 · "+n.Substring(9);
  if(n.StartsWith("Task:"))return (n.Contains("noninteractive")?"后台非交互运行 · ":"守护任务 · ")+n.Substring(5).Replace("noninteractive ","");
  if(n.StartsWith("Listener:"))return "本机监听端口 · "+n.Substring(9);
  if(n.StartsWith("DNS firewall:"))return "DNS 防火墙 · "+n.Substring(13);
  if(n.StartsWith("DNS:"))return "DNS 保护 · "+n.Substring(4).Replace("default route found","默认路由").Replace("adapter","网卡").Replace("bootstrap present","引导配置存在");
  return n.Replace("User:","用户代理 · ").Replace("Code:","Code 代理 · ").Replace("Desktop:","Desktop 代理 · ").Replace("Codex:","Codex 代理 · ").Replace("WinINet:","系统代理 · ").Replace("fixed proxy","固定代理").Replace("remote DNS","远端解析").Replace("connection flags","启用标志").Replace("no PAC","禁用自动代理脚本").Replace("bypass","绕过列表");
 }
 public Dashboard(string previewFile){preview=previewFile;Text="Claude 网络守护 v1.1";ClientSize=new Size(1100,840);MinimumSize=new Size(920,660);StartPosition=FormStartPosition.CenterScreen;BackColor=Color.FromArgb(243,246,250);Font=new Font("Microsoft YaHei UI",10);AutoScaleMode=AutoScaleMode.Dpi;
  var layout=new TableLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(24),ColumnCount=1,RowCount=5};layout.RowStyles.Add(new RowStyle(SizeType.Absolute,58));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,114));layout.RowStyles.Add(new RowStyle(SizeType.Percent,100));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,54));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,48));Controls.Add(layout);
  layout.Controls.Add(new Label{Text="Claude 网络守护   /   保护总览",Font=new Font(Font.FontFamily,22,FontStyle.Bold),ForeColor=Color.FromArgb(22,42,64),Dock=DockStyle.Fill},0,0);
  var summary=new TableLayoutPanel{Dock=DockStyle.Fill,BackColor=Color.White,Padding=new Padding(16,10,16,10),ColumnCount=1,RowCount=3,Margin=new Padding(0,0,0,12)};summary.RowStyles.Add(new RowStyle(SizeType.Absolute,30));summary.RowStyles.Add(new RowStyle(SizeType.Absolute,25));summary.RowStyles.Add(new RowStyle(SizeType.Percent,100));mode.Font=new Font(Font.FontFamily,16,FontStyle.Bold);mode.Text="读取后台状态…";mode.Dock=info.Dock=reason.Dock=DockStyle.Fill;reason.AutoEllipsis=true;reason.ForeColor=Color.Maroon;summary.Controls.Add(mode);summary.Controls.Add(info);summary.Controls.Add(reason);layout.Controls.Add(summary,0,1);
  cards.Dock=DockStyle.Fill;cards.FlowDirection=FlowDirection.TopDown;cards.WrapContents=false;cards.AutoScroll=true;cards.Margin=Padding.Empty;layout.Controls.Add(cards,0,2);for(int i=0;i<6;i++){groups[i]=new CheckCard(i);cards.Controls.Add(groups[i]);groups[i].UpdateRows(Titles[i],Descriptions[i],new List<Dictionary<string,object>>());}cards.SizeChanged+=delegate{ResizeCards();};
  var buttons=new FlowLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(0,10,0,0),Margin=Padding.Empty};Button check=new Button{Text="立即检查",AutoSize=true,Height=34};stop.Text="紧急锁定";stop.AutoSize=true;stop.Height=34;stop.BackColor=Color.FromArgb(160,43,53);stop.ForeColor=Color.White;unlock.Text="检查通过后手动解锁";unlock.AutoSize=true;unlock.Height=34;var logs=new Button{Text="查看报告与日志",AutoSize=true,Height=34};buttons.Controls.AddRange(new Control[]{check,stop,unlock,logs});layout.Controls.Add(buttons,0,3);
  layout.Controls.Add(new Label{Dock=DockStyle.Fill,ForeColor=Color.DimGray,Text="点击分类展开检查明细。关闭窗口不停止后台保护；出口检测超时仅提醒，确认出口 IP 不符时锁定。\n锁定会关闭 Claude 并中断任务。分类仅改变显示，不改变任何检查或防绕行规则。"},0,4);
  check.Click+=delegate{Command("check");};stop.Click+=delegate{Command("lock");};unlock.Click+=delegate{Command("unlock");};logs.Click+=delegate{Process.Start("explorer.exe","\""+Data.State+"\"");};Icon=new Icon(Path.Combine(Data.Root,"guard-icon.ico"));tray.Icon=Icon;tray.Text="Claude 网络守护 v1.1";tray.Visible=true;tray.DoubleClick+=delegate{Show();WindowState=FormWindowState.Normal;Activate();};timer.Interval=2000;timer.Tick+=delegate{RefreshState();};Shown+=delegate{ResizeCards();RefreshState();timer.Start();};FormClosed+=delegate{timer.Stop();timer.Dispose();tray.Dispose();};
 }
 void ResizeCards(){foreach(var card in groups)if(card!=null)card.Width=Math.Max(300,cards.ClientSize.Width-SystemInformation.VerticalScrollBarWidth-4);}
 void Command(string action){try{Data.Write(Path.Combine(Data.State,"command.json"),new{Action=action,At=DateTime.UtcNow.ToString("o"),Id=Guid.NewGuid().ToString()});reason.Text="请求已提交，等待后台处理。";}catch(Exception e){reason.Text=e.Message;}}
 void RefreshState(){try{
  var s=Data.Read(Path.Combine(Data.State,"status.json"));var sup=Data.Read(Path.Combine(Data.State,"supervisor.json"));var h=Data.Read(Path.Combine(Data.State,"health.json"));string m=Data.Text(s,"Mode");bool warning=false;foreach(object item in (object[])h["Checks"])if(Data.Text((Dictionary<string,object>)item,"Status")=="warning")warning=true;if(m=="HEALTHY"&&warning)m="WARNING";if(!Data.Fresh(s,10)||!Data.Fresh(sup,10))m="OFFLINE";
  var labels=new Dictionary<string,string>{{"WARNING","保护已启用 · 出口检测提醒"},{"HEALTHY","保护已启用 · 当前检查正常"},{"OBSERVE","观察模式 · 尚未启用自动停止"},{"LOCKED","已锁定 · 正在停止 Claude"},{"VERIFYING_UNLOCK","解锁核验中 · Claude 仍被停止"},{"ERROR","监控异常 · 请查看记录"},{"CHECKING","检查进行中"},{"OFFLINE","后台心跳失联 · 不能确认保护"}};mode.Text=labels.ContainsKey(m)?labels[m]:m;mode.ForeColor=m=="HEALTHY"?Color.SeaGreen:((m=="OBSERVE"||m=="WARNING")?Color.DarkGoldenrod:Color.Maroon);
  object lockObj;s.TryGetValue("Lock",out lockObj);var l=lockObj as Dictionary<string,object>;reason.Text=(l==null?"":"锁定原因："+Data.Text(l,"Reason")+"  ")+Data.Text(s,"Notice");
  string report=Data.Text(h,"At");if(report!=lastReport){int pass=0,fail=0,warn=0;var buckets=new List<Dictionary<string,object>>[6];for(int i=0;i<6;i++)buckets[i]=new List<Dictionary<string,object>>();string exit="待确认";foreach(object o in (object[])h["Checks"]){var c=(Dictionary<string,object>)o;string status=Data.Text(c,"Status"),name=Data.Text(c,"Name");if(status=="pass")pass++;else if(status=="warning")warn++;else if(status!="quarantined")fail++;buckets[Category(name)].Add(c);if(name=="Live:static exit"&&status=="pass")exit=Data.Text(h,"ExpectedExit");else if(name=="Live:static exit"&&status=="fail")exit="与目标不符";}
   cards.SuspendLayout();for(int i=0;i<6;i++)groups[i].UpdateRows(Titles[i],Descriptions[i],buckets[i]);var sorted=new List<CheckCard>(groups);sorted.Sort(delegate(CheckCard a,CheckCard b){int rank=b.Severity.CompareTo(a.Severity);return rank!=0?rank:a.Index.CompareTo(b.Index);});for(int i=0;i<sorted.Count;i++)cards.Controls.SetChildIndex(sorted[i],i);cards.ResumeLayout();DateTime t=DateTime.Parse(report,null,System.Globalization.DateTimeStyles.RoundtripKind);info.Text="当前出口 "+exit+"    |    "+pass+" / "+((object[])h["Checks"]).Length+" 项通过    提醒 "+warn+"    异常 "+fail+"    |    最近检查 "+t.ToLocalTime().ToString("HH:mm:ss");lastReport=report;
  }
  stop.Enabled=Data.Flag(s,"Armed")&&m!="OFFLINE";unlock.Enabled=m=="LOCKED";if(m!=lastMode&&(m=="LOCKED"||m=="ERROR"||m=="OFFLINE"||m=="WARNING"))tray.ShowBalloonTip(8000,"Claude 网络守护",mode.Text,ToolTipIcon.Warning);lastMode=m;
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
