# MonsterArmyV1

A UT2004 spectator war gametype: **two armies of 32 monsters** fight to the
death on **Onslaught battlefields**. The rosters are picked randomly from
the monster table (the same 200+ entry table MonsterFightClubV1 uses), and
every human on the server is locked into spectator mode to watch the show.

## How it plays

- A **matchup** books two random monster classes from the table
  (`[MonsterArmyV1.MonsterArmyMonsters]` in `System\MonsterArmyV1.ini`).
  With `bClonesArmy=False` the armies are a **mixed horde** instead - every
  one of the 64 monsters is its own random pick from the table.
- Each army spawns **32 monsters** (configurable) at opposite ends of the
  map, split around the two farthest-apart player starts.
- A round is **best-of-3** (configurable) and ends when:
  - an entire army is wiped out, or
  - the **5-minute** round clock expires (configurable) - then the army
    with the most monsters alive wins; a tie is a draw.
- After the rounds, the matchup winner is announced and **two fresh random
  armies** are chosen.
- The war runs **endlessly** - matchup after matchup - unless a
  `TimeLimit` is configured (`[Engine.GameInfo]` in the server ini, or
  `?TimeLimit=` in the URL); then the army with more round wins takes the
  show. The level never restarts.

## Files

| File | Purpose |
|------|---------|
| `Classes\MonsterArmyGame.uc` | the gametype (rounds, armies, enforcement) |
| `Classes\MonsterArmyMonsterController.uc` | army grudge AI (never camps, self-unstuck) |
| `Classes\MonsterArmyDriver.uc` | 1-second show driver (force-starts + drives the war) |
| `Classes\MonsterArmyMonsters.uc` | config object with the monster table |
| `Classes\MonsterArmyGRI.uc` | replicated war state for the HUD |
| `Classes\MonsterArmyHUD.uc` | the matchup/alive-count overlay |
| `Classes\MapListMonsterArmy.uc` | the 13 stock ONS maps |
| `MonsterArmyV1.ini` | gametype config + the full monster table |
| `make_server_ini.ps1` | builds `System\UT2004MonsterArmy.ini` from the MFC template |
| `RunServerMonsterArmy.bat` | server launcher (ONS-Torlan, auto-restarts) |

## Build

From `System\`:

```
powershell -ExecutionPolicy Bypass -File .\BuildDeployPush.ps1 -Package MonsterArmyV1
```

The package compiles via `EditPackages=MonsterArmyV1` in `UT2004_make.ini`,
the `.u` is moved to `Mods\System`, the redirect is updated, and the source
is synced to `C:\Projects\MonsterArmyV1` and pushed to GitHub.

## Run

```
powershell -ExecutionPolicy Bypass -File .\make_server_ini.ps1   (first time)
RunServerMonsterArmy.bat
```

Then join with `?game=MonsterArmyV1.MonsterArmyGame` on any ONS map (the
launcher uses ONS-Torlan).

## Config (System\MonsterArmyV1.ini)

```
[MonsterArmyV1.MonsterArmyGame]
ArmySize=32          ; monsters per army
bClonesArmy=True     ; True = each army is one class (2 classes per matchup),
                     ; False = every army member is a random monster from the table
RoundTimeLimit=300   ; seconds per round (5 min)
RoundsPerMatch=3     ; best-of-N rounds per matchup
ResultTime=5         ; seconds to linger on a round result
IntermissionTime=7   ; seconds between matchups
bOnlyONSMaps=True    ; refuse non-ONS maps
bBell=True           ; ring the bell at round start
BellVolume=255
```

URL overrides: `?ArmySize=`, `?RoundTimeLimit=`, `?RoundsPerMatch=`,
`?TimeLimit=` (0 = endless).
