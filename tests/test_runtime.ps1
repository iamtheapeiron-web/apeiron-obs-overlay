param([string]$Source = (Join-Path $PSScriptRoot "../runtime/overlay.ps1"))
$ErrorActionPreference="Stop"
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Source),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
$production=@{}
foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    $production[$node.Name]=$node.Extent.Text
    Invoke-Expression $node.Extent.Text
}
Add-Type @'
public class OverlayDouble {
    public bool Visible, PlacementMode;
    public string IconKind;
    public object FillColor, IconColor;
    public int Left=50, Top=50;
    public void Show(){Visible=true;}
    public void Hide(){Visible=false;}
    public void ForceTopMost(){}
    public void Invalidate(){}
    public void SetPlacementMode(bool enabled){PlacementMode=enabled;}
}
'@
function Apply-Appearance {}
function Hex-ToColor($value){return $value}
function Get-Date {return $script:now}
function Update-ElevationStatus {}
function OBS-Request([string]$type,$data=$null){
    if($script:failTransport){throw [IO.IOException]::new("Test transport disconnected")}
    switch($type){
        "GetInputList" {return @{inputs=$script:inputs}}
        "GetInputMute" {
            if($data.inputName -notin @($script:inputs.inputName)){
                $err=[InvalidOperationException]::new("OBS: Input not found")
                $err.Data["OBSCode"]=600;throw $err
            }
            if($data.inputName -eq "Video only"){
                $err=[InvalidOperationException]::new("OBS: Input has no audio")
                $err.Data["OBSCode"]=604;throw $err
            }
            return @{inputMuted=$script:mic}
        }
        "SetInputMute" {
            if($script:failSet){throw [IO.IOException]::new("Test write failed")}
            $script:mic=[bool]$data.inputMuted
            [void]$script:writes.Add(@{name=$data.inputName;muted=$script:mic})
            return @{}
        }
        default {throw "Unexpected mock request $type"}
    }
}
$mockRequest=(Get-Item Function:OBS-Request).ScriptBlock
function Assert([bool]$condition,[string]$message){
    $script:assertions++
    if(-not $condition){throw "Assertion $script:assertions failed: $message"}
}
function Reset-State {
    $script:now=[datetime]"2026-10-09T12:00:00Z"
    $script:cfg=Default-Config
    $cfg.obs.inputName="Studio microphone"
    $script:overlay=[OverlayDouble]::new()
    $script:overlayWanted=$false;$script:overlayMuted=$false;$script:overlayPersistent=$false
    $script:overlayHideAt=[datetime]::MaxValue
    $script:placement=$false;$script:previewActive=$false;$script:previewUntil=[datetime]::MinValue
    $script:baseMute=$false;$script:lastMute=$false;$script:mic=$false
    $script:connected=$true;$script:inputReady=$true;$script:ws=$null
    $script:holdActive=$false;$script:holdBaseMute=$null;$script:pendingRestore=$null
    $script:toggleWasDown=$false;$script:holdWasDown=$false
    $script:failTransport=$false;$script:failSet=$false
    $script:inputs=@(@{inputName="Studio microphone";inputKind="wasapi_input_capture"},@{inputName="Video only";inputKind="image_source"})
    $script:writes=[Collections.ArrayList]::new()
    $script:lastInputRefresh=$script:now;$script:lastReconnect=$script:now
    $script:lblStatus=[pscustomobject]@{Text=""}
}
function Want-Visible([bool]$muted,[string]$normal){
    return ($normal -eq "Show on change" -or ($normal -eq "Show only when muted" -and $muted) -or ($normal -eq "Show only when unmuted" -and -not $muted) -or ($normal -eq "Keep visible while muted" -and $muted))
}
$script:assertions=0
$normalModes=@("Show on change","Show only when muted","Show only when unmuted","Keep visible while muted","Never show")
$holdModes=@("Follow normal overlay rules","Always show while held","Don't show during Hold")
foreach($base in @($false,$true)){
 foreach($normal in $normalModes){
  foreach($hold in $holdModes){
   foreach($duration in @(0.2,1.0,2.5,10.0)){
    Reset-State
    $mic=$base;$baseMute=$base;$lastMute=$base
    $cfg.toggle.overlayBehavior=$normal;$cfg.toggle.duration=$duration;$cfg.hold.overlayBehavior=$hold
    Restore-BaseOverlay
    Process-ControlInput $true $true $true $true
    Assert ($holdActive -and $baseMute -eq $base -and $mic -eq (-not $base)) "Hold press wins simultaneous Toggle; $base/$normal/$hold/$duration"
    $visible=($hold -eq "Always show while held" -or ($hold -eq "Follow normal overlay rules" -and (Want-Visible (-not $base) $normal)))
    Assert ($overlay.Visible -eq $visible) "Hold overlay at press"
    $now=$now.AddSeconds($duration-0.01);Update-OverlayVisibility
    Assert ($overlay.Visible -eq $visible) "Popup before exact expiry"
    $now=$now.AddSeconds(0.01);Update-OverlayVisibility
    $persistent=($hold -eq "Always show while held" -or ($hold -eq "Follow normal overlay rules" -and $normal -eq "Keep visible while muted" -and -not $base))
    Assert ($overlay.Visible -eq $persistent) "Exact expiry while Hold is still held"
    $mic=$base;Poll-OBS
    Assert ($mic -eq (-not $base)) "External OBS change is corrected during Hold"
    Process-ControlInput $false $true
    Process-ControlInput $true $true $true $false
    Assert ($baseMute -eq $base -and $mic -eq (-not $base)) "Toggle consumed during Hold"
    Process-ControlInput $false $true
    Process-ControlInput $true $false $true $false
    Assert (-not $holdActive -and $mic -eq (-not $base) -and $baseMute -eq (-not $base)) "Release and Toggle in the same tick"
    Assert ($overlay.Visible -eq (Want-Visible (-not $base) $normal)) "Normal overlay after release plus Toggle"
    $now=$now.AddSeconds($duration);Update-OverlayVisibility
    Assert ($overlay.Visible -eq ($normal -eq "Keep visible while muted" -and -not $base)) "No lingering transient popup"
   }
  }
 }
}

# Release alone creates no popup, including a short Hold.
foreach($base in @($false,$true)){
 foreach($hold in $holdModes){
  foreach($normal in $normalModes){
    Reset-State;$mic=$base;$baseMute=$base;$lastMute=$base
    $cfg.toggle.overlayBehavior=$normal;$cfg.hold.overlayBehavior=$hold
    Hold-Press;Hold-Release
    Assert ($mic -eq $base -and -not $holdActive -and $null -eq $pendingRestore) "Short Hold restores its real base"
    Assert ($overlay.Visible -eq ($base -and $normal -eq "Keep visible while muted")) "No release popup"
  }
 }
}

# Preview uses the selected duration and restores the live layer.
foreach($duration in @(0.2,1,2.5,10)){
 Reset-State;$cfg.toggle.overlayBehavior="Keep visible while muted";$cfg.toggle.duration=$duration
 $mic=$true;$baseMute=$true;$lastMute=$true;Restore-BaseOverlay
 Show-Preview $false
 Assert ($overlay.IconKind -eq "Unmuted") "Preview state is independent"
 $now=$now.AddSeconds($duration-0.01);Update-OverlayVisibility
 Assert $previewActive "Preview is visible until the selected duration"
 $now=$now.AddSeconds(0.01);Update-OverlayVisibility
 Assert (-not $previewActive -and $overlay.Visible -and $overlay.IconKind -eq "Muted") "Persistent state restored after preview"
 Show-Preview $true;Hold-Press
 $now=$now.AddSeconds($duration);Update-OverlayVisibility
 Assert ($overlay.IconKind -eq "Unmuted" -and $holdActive) "Hold stays correct while preview ends"
 Hold-Release
}
Reset-State;$cfg.toggle.duration=0.2;Apply-ToggleOverlay $false;Show-Preview $true
$now=$now.AddSeconds(0.2);Update-OverlayVisibility
Assert (-not $overlay.Visible) "An expired normal popup is not revived after preview"

# Connection loss and write failure retain a target-specific restoration.
foreach($base in @($false,$true)){
 Reset-State;$mic=$base;$baseMute=$base;$lastMute=$base
 Hold-Press;$failTransport=$true;Poll-OBS
 Assert (-not $connected -and -not $holdActive -and -not $overlay.Visible -and $null -ne $pendingRestore) "Lost connection during Hold"
 $failTransport=$false;$connected=$true;$inputReady=$true
 Assert (Restore-PendingHold) "Pending restoration succeeds"
 Assert ($mic -eq $base -and $null -eq $pendingRestore) "Reconnect restores original state"
 Reset-State;$mic=$base;$baseMute=$base;$lastMute=$base
 Hold-Press;$failSet=$true;Hold-Release
 Assert (-not $connected -and $null -ne $pendingRestore) "Failed release is retained"
 $failSet=$false;$connected=$true;$inputReady=$true
 $old=$cfg.obs.inputName;$cfg.obs.inputName="Different microphone"
 $before=$writes.Count;Assert (Restore-PendingHold) "Different target is ignored"
 Assert ($writes.Count -eq $before -and $null -ne $pendingRestore) "No restoration to another input"
 $cfg.obs.inputName=$old;$null=Restore-PendingHold
 Assert ($mic -eq $base) "Original target restores when selected again"
}
Reset-State;Hold-Press;$cfg.hold.enabled=$false;Process-ControlInput $false $true
Assert (-not $holdActive -and -not $mic) "Disabling Hold restores the microphone"
Reset-State;$cfg.toggle.enabled=$false;Process-ControlInput $true $false $true $false
Assert ($writes.Count -eq 0) "Disabled Toggle does nothing"
Reset-State;$mic=$true;Poll-OBS
Assert ($baseMute -eq $true -and $overlay.Visible) "External change still drives overlay with native OBS controls"

# Deleted sources keep the socket connected and never select another source.
Reset-State;$inputs=@(@{inputName="Other audio";inputKind="wasapi_input_capture"})
Poll-OBS
Assert ($connected -and -not $inputReady -and -not $overlay.Visible) "Missing input does not disconnect the socket"
$cmbInput=[pscustomobject]@{Items=[Collections.ArrayList]::new();SelectedItem=$null;SelectedIndex=-1}
Refresh-InputList
Assert ($cmbInput.SelectedIndex -eq -1 -and $cfg.obs.inputName -eq "Studio microphone") "No automatic replacement microphone"
Reset-State
Assert (@(Get-ObsInputs).Count -eq 1) "Video-only input filtered by audio capability"

# Actual configuration migration, bounds and atomic write functions.
$testDir=Join-Path ([IO.Path]::GetTempPath()) ("apeiron-tests-"+[guid]::NewGuid().ToString("N"))
$null=New-Item -ItemType Directory $testDir
$configPath=Join-Path $testDir "settings.json"
try {
 $stored=Default-Config;$stored.schemaVersion=5;$stored.obs.inputName="Custom mic 名称"
 $stored.hold.overlayBehavior="Keep visible while held";$stored.toggle.duration=1.7
 Save-Config $stored;$loaded=Load-Config
 Assert ($loaded.schemaVersion -eq 6 -and $loaded.obs.inputName -eq "Custom mic 名称" -and $loaded.hold.overlayBehavior -eq "Always show while held" -and $loaded.toggle.duration -eq 1.7) "Current settings preserved and upgraded"
 $stored.toggle.duration=100;$stored.appearance.x=-2500;$stored.toggle.vk=$stored.hold.vk
 Save-Config $stored;$loaded=Load-Config
 Assert ($loaded.toggle.duration -eq 10 -and $loaded.appearance.x -eq -2500 -and -not $loaded.hold.enabled) "Invalid values clamped; key conflict disabled"
 Assert (Test-Path ($configPath+".bak")) "Atomic save keeps previous config"
 "invalid JSON" | Set-Content $configPath
 $loaded=Load-Config
 Assert ($loaded.toggle.duration -eq 2.5) "Corrupt config falls back safely"
} finally {Remove-Item $testDir -Recurse -Force}

# Check independent radio containers and the production event wiring.
$text=[IO.File]::ReadAllText((Resolve-Path $Source))
Assert ($text.Contains('$normalRadioPanel.Controls.Add($r)') -and $text.Contains('$holdRadioPanel.Controls.Add($r)')) "Two independent radio groups"
Assert ([regex]::Matches($text,'\$numToggleDur\.Add_ValueChanged').Count -eq 1) "One duration handler"
foreach($old in @("KeyName-ToVk","ignoreMuteUntil","lastObsPoll",'IconKind == "PTT"','IconKind == "PTM"')){
 Assert (-not $text.Contains($old)) "Obsolete code removed: $old"
}
foreach($event in @("btnTestMute","btnTestOn","mTestMute","mTestOn")){
 Assert ($text -match ('\$'+$event+'\.Add_Click\(\{[^}]*Show-Preview')) "All four preview buttons use configured duration"
}
$connectEvent=[regex]::Match($text,'(?s)\$btnConnect.Add_Click\(\{(.*?)\n\}\)').Groups[1].Value
Assert (-not $connectEvent.Contains("Apply-And-Save") -and -not $connectEvent.Contains("Copy-UI-ToConfig")) "Connect cannot save unrelated tabs"

# Exercise the actual placement exit and OBS-only config copy.
function Fake-AppearanceUI {
 $script:cmbShape=[pscustomobject]@{SelectedItem="Circle"}
 $script:numSize=[pscustomobject]@{Value=72}
 $script:numOpacity=[pscustomobject]@{Value=88}
 $script:numX=[pscustomobject]@{Value=50;Minimum=-10000;Maximum=10000}
 $script:numY=[pscustomobject]@{Value=50;Minimum=-10000;Maximum=10000}
 $script:cmbMonitor=[pscustomobject]@{SelectedItem="Primary monitor"}
 $script:btnMutedColor=[pscustomobject]@{Text="#D23B3B"}
 $script:btnUnmutedColor=[pscustomobject]@{Text="#2FA866"}
 $script:btnIconColor=[pscustomobject]@{Text="#FFFFFF"}
 $script:btnPlace=[pscustomobject]@{Text="Finish placement";UseVisualStyleBackColor=$false;Font="bold";Enabled=$true;BackColor="green";ForeColor="black"}
 $script:placeBackColor="normal-color";$script:placeForeColor="normal-text"
 $script:lblPlacement=[pscustomobject]@{Text="";Enabled=$true}
 $script:tabLook=[pscustomobject]@{Controls=@([pscustomobject]@{Enabled=$false},$script:btnPlace)}
 $script:form=[pscustomobject]@{Font="normal"}
}
Reset-State;Fake-AppearanceUI
$baseMute=$true;$cfg.toggle.overlayBehavior="Keep visible while muted";Restore-BaseOverlay
$placement=$true;$overlay.SetPlacementMode($true);$overlay.Left=345;$overlay.Top=-120
Show-Preview $false
Assert (-not $previewActive) "Preview cannot displace placement"
Finish-Placement
Assert (-not $placement -and -not $overlay.PlacementMode -and $cfg.appearance.x -eq 345 -and $cfg.appearance.y -eq -120) "Placement exits and keeps dragged coordinates"
Assert ($overlay.Visible -and $overlayPersistent -and $btnPlace.Text -eq "Place by dragging") "Placement restores persistent overlay and button"
Assert ($tabLook.Controls[0].Enabled) "Appearance controls re-enabled on finish"
Assert ($btnPlace.BackColor -eq "normal-color" -and $btnPlace.ForeColor -eq "normal-text") "Placement button restores its original colors"
Reset-State;Fake-AppearanceUI
Apply-ToggleOverlay $false;$placement=$true;$now=$now.AddSeconds(5)
Finish-Placement
Assert (-not $overlay.Visible) "Expired popup is not revived by Finish placement"
Reset-State
$txtHost=[pscustomobject]@{Text="127.0.0.1"}
$numPort=[pscustomobject]@{Value=4455}
$txtPass=[pscustomobject]@{Text="unit-test-session-secret"}
$chkRemember=[pscustomobject]@{Checked=$false}
$chkAuto=[pscustomobject]@{Checked=$true}
$cmbInput=[pscustomobject]@{SelectedItem="Studio microphone"}
Copy-OBS-UI-ToConfig
Assert ($sessionPassword -eq $txtPass.Text -and $cfg.obs.passwordProtected -eq "" -and -not $cfg.obs.rememberPassword) "Session password remains in memory when Remember is off"
$normal=$cfg.toggle.overlayBehavior;$cfg.general.startWithWindows=$false
Hold-Press;$cmbInput.SelectedItem="Another microphone";Copy-OBS-UI-ToConfig
Assert (-not $holdActive -and -not $connected -and -not $mic -and $writes[$writes.Count-1].name -eq "Studio microphone") "Changing selected input restores the old input first"
Assert ($cfg.toggle.overlayBehavior -eq $normal -and -not $cfg.general.startWithWindows) "OBS copy does not apply other tabs"
$resetEvent=[regex]::Match($text,'(?s)\$btnReset.Add_Click\(\{(.*?)\n\}\)').Groups[1].Value
Assert ($resetEvent.Contains('$cfg.general.startWithWindows=$false') -and $resetEvent.Contains("Update-Autostart")) "Reset removes the app's startup shortcut"
Assert (-not $text.Contains("START.vbs")) "Obsolete VBS startup fallback removed"

# Build 3 startup visibility contract.
Assert ($text.Contains('[switch]$StartupMode')) "Explicit Windows-startup marker exists"
Assert ($text.Contains('Start hidden in tray with Windows')) "Startup-only wording is shown in General"
Assert ($text.Contains("-StartupMode'")) "Windows Startup shortcut passes the marker"
Assert ($text.Contains('if ($StartupMode -and $cfg.general.startMinimized')) "Hidden startup requires StartupMode"
Assert ($text.Contains('$form.Show();$form.BringToFront();$form.Activate()')) "Manual/admin launch explicitly restores Settings visibility"
Write-Output ("PASS: "+$assertions+" assertions against extracted production functions and event wiring.")
