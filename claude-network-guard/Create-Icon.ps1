$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$sizes=@(16,24,32,48,64,128,256)
$images=@()
foreach($size in $sizes){
 $b=New-Object Drawing.Bitmap ($size,$size)
 $g=[Drawing.Graphics]::FromImage($b)
 $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
 $g.ScaleTransform($size/256.0,$size/256.0)
 $shield=New-Object Drawing.Drawing2D.GraphicsPath
 $shield.AddLines([Drawing.PointF[]]@([Drawing.PointF]::new(128,12),[Drawing.PointF]::new(224,48),[Drawing.PointF]::new(218,134)))
 $shield.AddBezier(218,134,212,184,170,220,128,244)
 $shield.AddBezier(128,244,86,220,44,184,38,134)
 $shield.AddLine(38,134,32,48)
 $shield.CloseFigure()
 $fill=New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(40,20)),([Drawing.Point]::new(210,240)),([Drawing.Color]::FromArgb(32,124,218)),([Drawing.Color]::FromArgb(15,42,91))
 $g.FillPath($fill,$shield)
 $rim=New-Object Drawing.Pen ([Drawing.Color]::FromArgb(105,200,255)),5
 $g.DrawPath($rim,$shield)
 $line=New-Object Drawing.Pen ([Drawing.Color]::FromArgb(118,221,241)),10
 $line.StartCap=$line.EndCap=[Drawing.Drawing2D.LineCap]::Round
 $g.DrawLine($line,86,89,128,128);$g.DrawLine($line,170,89,128,128);$g.DrawLine($line,128,128,128,187)
 $white=New-Object Drawing.SolidBrush ([Drawing.Color]::White)
 foreach($pt in @(@(86,89),@(170,89),@(128,187))){$g.FillEllipse($white,($pt[0]-13),($pt[1]-13),26,26)}
 $mint=New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(78,235,180))
 $g.FillEllipse($mint,104,104,48,48)
 $check=New-Object Drawing.Pen ([Drawing.Color]::FromArgb(12,65,68)),7
 $check.StartCap=$check.EndCap=[Drawing.Drawing2D.LineCap]::Round
 $g.DrawLines($check,[Drawing.PointF[]]@([Drawing.PointF]::new(116,128),[Drawing.PointF]::new(125,136),[Drawing.PointF]::new(140,119)))
 $ms=New-Object IO.MemoryStream
 $b.Save($ms,[Drawing.Imaging.ImageFormat]::Png)
 $images+=,$ms.ToArray()
 if($size -eq 256){$b.Save("$PSScriptRoot\guard-icon.png",[Drawing.Imaging.ImageFormat]::Png)}
 foreach($obj in @($ms,$check,$mint,$white,$line,$rim,$fill,$shield,$g,$b)){$obj.Dispose()}
}
$stream=[IO.File]::Create("$PSScriptRoot\guard-icon.ico")
$writer=New-Object IO.BinaryWriter $stream
$writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
$offset=6+16*$sizes.Count
for($i=0;$i -lt $sizes.Count;$i++){
 $dimension=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
 $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
 $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$images[$i].Length);$writer.Write([uint32]$offset)
 $offset+=$images[$i].Length
}
foreach($bytes in $images){$writer.Write([byte[]]$bytes)}
$writer.Dispose();$stream.Dispose()
