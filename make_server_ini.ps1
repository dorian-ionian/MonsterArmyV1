#=============================================================================
# make_server_ini.ps1 - builds System\UT2004MonsterArmy.ini from the proven
# UT2004MFC.ini server template (server packages, voting config, redirect,
# paths) and swaps the MFC gametype for MonsterArmyV1.
#
# Usage: powershell -ExecutionPolicy Bypass -File .\make_server_ini.ps1
#
# Outputs:
#   System\UT2004MonsterArmy.ini - the server ini for RunServerMonsterArmy.bat
#=============================================================================
$ErrorActionPreference = "Stop"
$g = "C:\Program Files (x86)\Steam\steamapps\common\Unreal Tournament 2004"
$src = "$g\System\UT2004MFC.ini"
$dst = "$g\System\UT2004MonsterArmy.ini"
$projIni = "$g\MonsterArmyV1\MonsterArmyV1.ini"

if (-not (Test-Path $src)) { Write-Error "Template missing: $src"; exit 1 }
if (-not (Test-Path $projIni)) { Write-Error "Project ini missing: $projIni"; exit 1 }

$lines = [System.Collections.Generic.List[string]](Get-Content $src)

#--- 1. swap gametype references -------------------------------------------
for ($i = 0; $i -lt $lines.Count; $i++)
{
    $l = $lines[$i]
    if ($l -eq "ServerPackages=MonsterFightClubV1")
        { $lines[$i] = "ServerPackages=MonsterArmyV1" }
    elseif ($l -eq "EditPackages=MonsterFightClubV1")
        { $lines[$i] = "EditPackages=MonsterArmyV1" }
    elseif ($l -match '^Games=\(GameType="MonsterFightClubV1')
        { $lines[$i] = 'Games=(GameType="MonsterArmyV1.MonsterArmyGame",ActiveMaplist="Default MAR")' }
    elseif ($l -match '^GameConfig=\(GameClass="MonsterFightClubV1')
        { $lines[$i] = 'GameConfig=(GameClass="MonsterArmyV1.MonsterArmyGame",Prefix="ONS",Acronym="MAR",GameName="Monster Army",Mutators=,Options=)' }
}

#--- 2. replace the MFC map list + maplist record blocks -------------------
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++)
{
    if ($lines[$i] -match '^\[MonsterFightClubV1\.MapListMonsterFightClub\]') { $start = $i; break }
}
if ($start -ge 0)
{
    $end = $start + 1
    while ($end -lt $lines.Count -and $lines[$end] -notmatch '^\[MonsterFightClubV1\.MonsterFightClubGame\]')
        { $end++ }

    $maps = @('ONS-Adara','ONS-ArcticStronghold','ONS-Crossfire','ONS-Dawn','ONS-Dria',
              'ONS-FrostBite','ONS-IslandHop','ONS-Primeval','ONS-RedPlanet','ONS-Severance',
              'ONS-Torlan','ONS-Tricky','ONS-Urban')
    $block = [System.Collections.Generic.List[string]]@('[MonsterArmyV1.MapListMonsterArmy]', 'MapNum=0')
    foreach ($m in $maps) { $block.Add("Maps=$m") }
    $block.Add('[Default MAR MaplistRecord]')
    $block.Add('DefaultTitle=Default MAR')
    $block.Add('DefaultGameType=MonsterArmyV1.MonsterArmyGame')
    $block.Add('DefaultActive=0')
    foreach ($m in $maps) { $block.Add("DefaultMaps=$m") }

    $lines.RemoveRange($start, $end - $start)
    $lines.InsertRange($start, $block)
}

#--- 3. replace the game config sections ------------------------------------
# find [MonsterFightClubV1.MonsterFightClubGame] .. EOF and rebuild
$cfgStart = -1
for ($i = 0; $i -lt $lines.Count; $i++)
{
    if ($lines[$i] -match '^\[MonsterFightClubV1\.MonsterFightClubGame\]') { $cfgStart = $i; break }
}
if ($cfgStart -ge 0)
{
    $lines.RemoveRange($cfgStart, $lines.Count - $cfgStart)

    # [MonsterArmyV1.MonsterArmyGame] config from the project ini
    # (the monster table itself lives in System\MonsterArmyV1.ini - that
    # file is the config target of the MonsterArmyMonsters class)
    $cfg = Get-Content $projIni
    $cfgLines = [System.Collections.Generic.List[string]]@('[MonsterArmyV1.MonsterArmyGame]')
    for ($i = 1; $i -lt $cfg.Count; $i++)
    {
        if ($cfg[$i] -match '^\[') { break }   # stop at the next section
        $cfgLines.Add($cfg[$i])
    }
    $lines.InsertRange($cfgStart, $cfgLines)
}

#--- 4. [Engine.GameInfo] TimeLimit so the stock match timer runs -----------
for ($i = 0; $i -lt $lines.Count - 1; $i++)
{
    if ($lines[$i] -eq "[Engine.GameInfo]" -and $lines[$i + 1] -match '^TimeLimit=')
        { $lines[$i + 1] = "TimeLimit=15"; break }
}

#--- 5. Server name + redact secrets -----------------------------------------
for ($i = 0; $i -lt $lines.Count; $i++)
{
    if ($lines[$i] -match '^ServerName=')
        { $lines[$i] = "ServerName=Monster Army (Test)" }
    elseif ($lines[$i] -match '^AdminPassword=')
        { $lines[$i] = "AdminPassword=CHANGE_ME" }
    elseif ($lines[$i] -match '^GamePassword=')
        { $lines[$i] = "GamePassword=CHANGE_ME" }
    elseif ($lines[$i] -match '^SavedPasswords=')
        { $lines[$i] = "SavedPasswords=" }
}

Set-Content -Path $dst -Value $lines -Encoding ASCII
Write-Host "Wrote $dst ($($lines.Count) lines)"
