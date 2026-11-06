# reap.ps1 — end the processes a run left behind under C:\hx-<issue>\ (#492). Tests leak watchers (an attach.sh and its
# claude_headless.py watch, a cat on a lane pid file) and each one keeps the ssh session's stdout open, so the run's own
# exit cannot reach the claude host until cleanup kills them. Run by suite.sh once run.sh has finished, with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File reap.ps1 -Me <winpid of the caller> -Issue <n> [-DryRun]
# Kills only a process whose command line names the run folder (hx-<issue>), is not the caller or one of its ancestors
# (the ssh bash, the bash -c that runs the suite) and is not the lock's heartbeat loop (hb.sh, which cleanup stops).
param([int]$Me, [string]$Issue, [switch]$DryRun)
$all = @(Get-CimInstance Win32_Process)
$anc = @{}
$p = $Me
while ($p -and -not $anc.ContainsKey($p)) {
  $anc[$p] = 1
  $q = $all | Where-Object { $_.ProcessId -eq $p } | Select-Object -First 1
  if (-not $q) { break }
  $p = [int]$q.ParentProcessId
}
$rx = '[\\/]hx-' + [regex]::Escape($Issue) + '([\\/ ]|$)'
foreach ($proc in $all) {
  $id = [int]$proc.ProcessId
  if ($id -eq $PID -or $anc.ContainsKey($id) -or -not $proc.CommandLine) { continue }
  if ($proc.CommandLine -notmatch $rx -or $proc.CommandLine -match 'hb\.sh') { continue }
  $short = $proc.CommandLine.Substring(0, [Math]::Min(110, $proc.CommandLine.Length))
  if ($DryRun) { "would reap $id $($proc.Name) $short" }
  else { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; "reaped $id $($proc.Name) $short" }
}
