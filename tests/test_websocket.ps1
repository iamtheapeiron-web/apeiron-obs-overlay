param([int]$Port, [string]$Source=(Join-Path $PSScriptRoot "../runtime/overlay.ps1"))
$ErrorActionPreference="Stop"
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Source),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($n in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $n.Extent.Text}
function Update-ElevationStatus {}
function Hide-Overlay {}
function Restore-BaseOverlay {}
function Apply-ToggleOverlay($muted){}
function Apply-HoldOverlay {}
function Assert([bool]$condition,[string]$message){$script:checks++;if(-not $condition){throw $message}}
$script:checks=0
$cfg=Default-Config;$cfg.obs.host="127.0.0.1";$cfg.obs.port=$Port;$cfg.obs.inputName="Studio microphone"
$cfg.obs.rememberPassword=$false;$cfg.obs.passwordProtected=""
$script:connected=$false;$script:ws=$null;$script:reqId=0;$script:inputReady=$false
$script:lastMute=$null;$script:baseMute=$null;$script:holdActive=$false;$script:holdBaseMute=$null
$script:pendingRestore=$null;$script:passwordRequired=$false;$script:refreshingInputs=$false
$script:lastReconnect=[datetime]::MinValue;$script:lastInputRefresh=[datetime]::MinValue
$script:sessionPassword="fixture-only-password"
$overlay=$null
$lblStatus=[pscustomobject]@{Text=""}
$cmbInput=[pscustomobject]@{Items=[Collections.ArrayList]::new();SelectedItem=$null;SelectedIndex=-1}
try {
 Assert (Connect-OBS $cfg.obs.host $Port $script:sessionPassword) "Authenticated OBS v5 handshake failed"
 Refresh-InputList
 Assert ($connected -and $inputReady -and $cmbInput.Items.Count -eq 1) "Audio capability filter failed"
 Poll-OBS
 Assert ($baseMute -eq $false) "Initial state missing"
 Toggle-Microphone
 Assert (Get-InputMute $cfg.obs.inputName) "Toggle did not write through the socket"
 Hold-Press
 Assert ($holdActive -and -not (Get-InputMute $cfg.obs.inputName)) "Hold did not invert"
 $null=OBS-Request "_testSetExternal" @{muted=$true}
 Poll-OBS
 Assert (-not (Get-InputMute $cfg.obs.inputName)) "Hold failed to correct external OBS change"
 Hold-Release
 Assert (-not $holdActive -and (Get-InputMute $cfg.obs.inputName)) "Hold failed to restore"
 $null=OBS-Request "_testRemoveInput"
 Poll-OBS
 Assert ($connected -and -not $inputReady) "Missing input caused a reconnect loop"
 Refresh-InputList
 Assert ($cmbInput.Items.Count -eq 0 -and $cmbInput.SelectedIndex -eq -1) "A different input was selected"
 $null=OBS-Request "_testRestoreInput"
 Refresh-InputList;Poll-OBS
 Assert ($connected -and $inputReady) "Restored selected input was not recovered"
 Disconnect-OBS;$lastReconnect=[datetime]::MinValue
 Poll-OBS;Poll-OBS
 Assert ($connected -and $inputReady -and $cfg.obs.passwordProtected -eq "" -and (Get-InputMute $cfg.obs.inputName)) "Reconnect failed with session-only password"
 Hold-Press;Disconnect-OBS;$lastReconnect=[datetime]::MinValue
 Poll-OBS;Poll-OBS
 Assert ($connected -and -not $holdActive -and $null -eq $pendingRestore -and (Get-InputMute $cfg.obs.inputName)) "Hold restoration across a real socket reconnect failed"
 Hold-Press
 $null=OBS-Request "_testDropConnection"
 Poll-OBS
 Assert (-not $connected -and -not $holdActive -and $null -ne $pendingRestore) "An abrupt server disconnect lost Hold restoration"
 $lastReconnect=[datetime]::MinValue;Poll-OBS;Poll-OBS
 Assert ($connected -and (Get-InputMute $cfg.obs.inputName) -and $null -eq $pendingRestore) "Recovery from an abrupt server disconnect failed"
 Disconnect-OBS
 Assert (-not (Connect-OBS $cfg.obs.host $Port "" -Quiet)) "Empty password unexpectedly authenticated"
 Assert $passwordRequired "Missing saved password was not surfaced"
 $passwordRequired=$false
 Assert (-not (Connect-OBS $cfg.obs.host $Port "wrong-fixture-password" -Quiet)) "Wrong password unexpectedly authenticated"
 Assert $passwordRequired "Authentication failure was not surfaced"
 Assert (Connect-OBS $cfg.obs.host $Port $script:sessionPassword) "Correct password did not recover after failed auth"
 $null=OBS-Request "_testAuthOff"
 Disconnect-OBS
 Assert (Connect-OBS $cfg.obs.host $Port "") "OBS without authentication did not connect"
 Assert (-not $passwordRequired) "Authentication-disabled OBS incorrectly asks for a password"
 Write-Output ("PASS: "+$checks+" real WebSocket integration assertions.")
} finally {Disconnect-OBS}
