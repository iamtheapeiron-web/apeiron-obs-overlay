param([string]$Source,[string]$ReferenceDir,[string]$Output)
$ErrorActionPreference="Stop"
$text=[IO.File]::ReadAllText($Source)
$native=[regex]::Match($text,'(?s)\$native = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
if(-not $native){throw "No production C# block"}
$parseOptions=[Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithLanguageVersion([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
$tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($native,$parseOptions)
$trees=[Microsoft.CodeAnalysis.SyntaxTree[]]@($tree)
$references=[Microsoft.CodeAnalysis.MetadataReference[]]@(
 [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDir "mscorlib.dll")),
 [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDir "System.dll")),
 [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDir "System.Drawing.dll")),
 [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDir "System.Windows.Forms.dll"))
)
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create("ApeironNative",$trees,$references,$options)
$stream=[IO.File]::Create($Output)
try{$result=$compilation.Emit($stream)}finally{$stream.Dispose()}
if(-not $result.Success){$result.Diagnostics | ForEach-Object {$_.ToString()};throw "Production native C# compilation failed"}
Write-Output "PASS: production native C# compiled against .NET Framework reference assemblies with C# 5 syntax."
