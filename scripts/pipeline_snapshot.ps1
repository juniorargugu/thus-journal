#Requires -Version 5.1
# ===========================================================================
# THUS Journal - pipeline read-only snapshot.
# NO writes, NO DB, NO network, NO SQL. Safe for autopilot to run.
# Prints git state + code markers + key-file presence, then exits.
# ===========================================================================
$ErrorActionPreference = 'Continue'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

Write-Host "=== THUS Journal pipeline snapshot (read-only) ==="
Write-Host ("repo : " + $repo)
Write-Host ""

Write-Host "--- git branch ---"
git rev-parse --abbrev-ref HEAD

Write-Host "--- HEAD ---"
git log -1 --oneline

Write-Host "--- git status --short ---"
$st = git status --short
if ([string]::IsNullOrWhiteSpace($st)) { Write-Host "(clean)" } else { Write-Host $st }

Write-Host "--- git log --oneline -10 ---"
git log --oneline -10

Write-Host "--- ahead/behind origin/main ---"
$lr = git rev-list --left-right --count origin/main...HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $lr) {
    $p = ($lr -split "\s+")
    Write-Host ("behind origin/main : " + $p[0] + "   ahead : " + $p[1])
} else {
    Write-Host "(origin/main not available)"
}
Write-Host ""

function Marker([string]$label, [string]$file, [string]$pattern) {
    if (Test-Path $file) {
        $c = (Select-String -Path $file -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host ("{0,-46} {1}" -f $label, $c)
    } else {
        Write-Host ("{0,-46} FILE MISSING" -f $label)
    }
}

function FileExists([string]$label, [string]$file) {
    if (Test-Path $file) { Write-Host ("{0,-46} OK" -f $label) }
    else { Write-Host ("{0,-46} MISSING" -f $label) }
}

Write-Host "--- code markers (index.html, line-match counts) ---"
Marker "create_trade_group_v1 refs"        "index.html" "create_trade_group_v1"
Marker "tj_trade_group_ui_v01 refs"        "index.html" "tj_trade_group_ui_v01"
Marker "tj_trade_group_write_v01 refs"     "index.html" "tj_trade_group_write_v01"
Marker "P2-5D forbidden __tjP25DBackfill"  "index.html" "__tjP25DBackfill"
Marker "P2-5D forbidden dev flag"          "index.html" "tj_p2_5d_backfill_dev"

Write-Host ""
Write-Host "--- key files present ---"
FileExists "migration 20260705 g2 rpcs"    "migrations/20260705_g2_trade_group_rpcs.sql"
FileExists "PIPELINE_STATE.md"             "artifacts/pipeline/PIPELINE_STATE.md"
FileExists "AUTOPILOT_RULES.md"            "artifacts/pipeline/AUTOPILOT_RULES.md"
FileExists "NEXT_SAFE_TASK.md"             "artifacts/pipeline/NEXT_SAFE_TASK.md"
FileExists "g2_candidate_check.sql"        "artifacts/pipeline/g2_candidate_check.sql"
FileExists "pipeline_snapshot.ps1"         "scripts/pipeline_snapshot.ps1"

Write-Host ""
Write-Host "note: forbidden P2-5D markers must be 0; write-gate is read-only + default-off."
Write-Host "=== end snapshot (no writes performed) ==="
