# WAV を AAC(.m4a)に変える。Windows に元からある変換機能(MediaTranscoder)を使う。
# 使い方(-MTA が必要。ないと終わっても戻らない): powershell -MTA -ExecutionPolicy Bypass -File to_m4a.ps1 入力フォルダ 出力フォルダ [kbps]
# 出力は 48kHz ステレオ。先頭の遅れ(エンコーダーの前置き)は入らない(Windows で戻して確認ずみ)
param([string]$InDir, [string]$OutDir, [int]$Kbps = 128)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Transcoding.MediaTranscoder, Windows.Media.Transcoding, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncActionWithProgress`1' })[0]
function Await($op, [Type]$t) {
    $task = $asTaskGeneric.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result }
function AwaitProgress($op, [Type]$p) {
    # AsTask で待つと終わっても戻らないことがあるので、状態を見て待つ(1: 完了、2: 中止、3: 失敗)
    $limit = [DateTime]::Now.AddSeconds(60)
    while ([int]$op.Status -eq 0) {
        if ([DateTime]::Now -gt $limit) { $op.Cancel(); throw 'timeout' }
        Start-Sleep -Milliseconds 30
    }
    if ([int]$op.Status -ne 1) { throw "transcode failed: $($op.ErrorCode)" }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$outFolder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync((Resolve-Path $OutDir).Path)) ([Windows.Storage.StorageFolder])
$quality = [Windows.Media.MediaProperties.AudioEncodingQuality]::High
$transcoder = New-Object Windows.Media.Transcoding.MediaTranscoder
foreach ($f in Get-ChildItem -Path $InDir -Filter *.wav) {
    $name = [IO.Path]::GetFileNameWithoutExtension($f.Name) + '.m4a'
    if (Test-Path (Join-Path $OutDir $name)) { continue }
    $src = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($f.FullName)) ([Windows.Storage.StorageFile])
    $dst = Await ($outFolder.CreateFileAsync($name, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    $profile = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateM4a($quality)
    $profile.Audio.Bitrate = [uint32]($Kbps * 1000)
    $prep = Await ($transcoder.PrepareFileTranscodeAsync($src, $dst, $profile)) ([Windows.Media.Transcoding.PrepareTranscodeResult])
    if (-not $prep.CanTranscode) { Write-Output "skip $($f.Name): $($prep.FailureReason)"; continue }
    $t = $asTaskAction.MakeGenericMethod([double]).Invoke($null, @($prep.TranscodeAsync())); if (-not $t.Wait(30000)) { throw "timeout" }; if ($t.IsFaulted) { throw $t.Exception }
    Write-Output "ok $name"
}
