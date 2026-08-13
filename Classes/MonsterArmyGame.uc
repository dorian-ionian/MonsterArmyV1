//=============================================================================
// MonsterArmyGame
//
// Spectator war gametype for UT2004: two armies of monsters - 32 monsters
// each by default - fight to the death on Onslaught battlefields. The
// rosters are picked randomly from the monster table (see
// MonsterArmyMonsters, editable in System\MonsterArmyV1.ini), and every
// human on the server is locked into spectator mode to watch the show.
//
// A match is best-of-N rounds (3 by default). A round ends when an entire
// army is wiped out, or when the round clock expires (5 minutes by
// default) - in that case the army with the most monsters alive wins. A
// tie on time (or a simultaneous double wipe) is a draw.
//
// After the rounds the matchup winner is announced and two NEW random
// armies are chosen. The war runs ENDLESSLY - matchup after matchup -
// unless a TimeLimit is configured ([Engine.GameInfo] or ?TimeLimit= in
// the URL); then the army with more round wins takes the show.
//=============================================================================

// The round-start bell. Imported into this package at build time - ucc make
// runs this exec before compiling, so the wav must exist when building.
#exec AUDIO IMPORT NAME="BellSound" FILE="..\MonsterArmyV1\Sounds\bell_22050.wav"

class MonsterArmyGame extends xDeathMatch
    config(MonsterArmyV1);

//------------------------------------------------------------------------------
// Configurable war settings (see System\MonsterArmyV1.ini)
//------------------------------------------------------------------------------
var() config int    ArmySize;           // monsters per army (default 32)
var() config int    RoundTimeLimit;     // seconds per round before the
                                        // alive-count decision (default 300)
var() config int    RoundsPerMatch;     // best-of-N rounds per matchup (default 3)
var() config float  ResultTime;         // seconds to linger on a round result (default 5)
var() config float  IntermissionTime;   // seconds between matchups (default 7)
var() config bool   bOnlyONSMaps;       // only allow ONS-* maps (default true)
var() config bool   bBell;              // ring the bell when a round starts
var() config byte   BellVolume;         // bell volume (0-255)
var() config bool   bLogDamage;         // debug: log army damage events
var() config string DebugStatus;        // live war state, written to the ini for admins

//------------------------------------------------------------------------------
// Phase constants (mirrored in MonsterArmyGRI for the HUD)
//------------------------------------------------------------------------------
const PHASE_IDLE          = 0;
const PHASE_FIGHT         = 1;
const PHASE_RESULT        = 2;
const PHASE_INTERMISSION  = 3;

var int  Phase;                     // current war phase
var int  RoundNumber;               // current round within the matchup (1-based)
var int  MatchupNumber;             // how many matchups have been booked
var int  RoundWins[2];              // round wins per army in the current matchup
var int  TotalWins[2];              // round wins across the whole show
var int  AliveA, AliveB;            // living monster counts (replicated via GRI)
var float PhaseClock;               // seconds spent in the current phase
var float StatusClock;              // accumulator for the ini telemetry
var int  SpawnWindowTicks;          // how many spawn-topup ticks have run
var int  MapSwitchClock;            // countdown to the ONS map switch

var bool bShowStarted;
var bool bShowEnded;
var bool bSpawnWindowOpen;          // initial spawns may still top up
var bool bMapSwitchPending;

var class<Monster> ArmyAClass, ArmyBClass;
var string ArmyAName, ArmyBName;

var array<Monster> ArmyA, ArmyB;            // live + dead roster of the round
var array<int> ArmyClusterA, ArmyClusterB;  // spawn spot indices per army
var array<PlayerStart> StartSpots;
var string FirstSupportedMap;

var MonsterArmyGRI MAGRI;
var sound BellSound;
var bool bDriverActive;     // the MonsterArmyDriver owns the 1Hz war clock

//==============================================================================
// Initialization
//==============================================================================

event InitGame(string Options, out string Error)
{
    local string InOpt;

    Super.InitGame(Options, Error);

    // Keep the standard 32-slot server capacity (unless explicitly overridden
    // in the map URL with ?MaxPlayers=).
    InOpt = ParseOption(Options, "MaxPlayers");
    if (InOpt == "")
        MaxPlayers = 32;
    MaxSpectators = 32;   // every human is a spectator in this war!

    // War length (default 0 = endless matchups; standard ?TimeLimit=
    // override and [Engine.GameInfo] TimeLimit= both work)
    TimeLimit = Clamp(GetIntOption(Options, "TimeLimit", TimeLimit), 0, 480);
    RemainingTime = 60 * TimeLimit;
    if (GameReplicationInfo != None)
        GameReplicationInfo.TimeLimit = TimeLimit;

    // Our own URL overrides
    ArmySize        = Max(1, GetIntOption(Options, "ArmySize", default.ArmySize));
    RoundTimeLimit  = Max(10, GetIntOption(Options, "RoundTimeLimit", default.RoundTimeLimit));
    RoundsPerMatch  = Clamp(GetIntOption(Options, "RoundsPerMatch", default.RoundsPerMatch), 1, 9);

    // The war runs even with zero humans on the server
    bWaitForNetPlayers = false;
    MinNetPlayers = 0;   // PendingMatch re-enables bWaitForNetPlayers with 0 players; this lets it time out

    MAGRI = MonsterArmyGRI(GameReplicationInfo);
    if (MAGRI != None)
        MAGRI.RoundsTotal = RoundsPerMatch;

    BuildFirstSupportedMap();
    CheckCurrentMap();

    DebugWrite("init");
}

function PostBeginPlay()
{
    Super.PostBeginPlay();
    CollectStartSpots();

    // The GRI actor is spawned inside Super.PostBeginPlay - grab it NOW.
    MAGRI = MonsterArmyGRI(GameReplicationInfo);
    if (MAGRI != None)
    {
        MAGRI.RoundsTotal = RoundsPerMatch;
        MAGRI.NetUpdateTime = Level.TimeSeconds - 1;
        log("MonsterArmy: GRI ready", 'MonsterArmyV1');
    }
    else
        log("MonsterArmy: MAGRI is None at PostBeginPlay", 'MonsterArmyV1');

    // Dedicated war driver: ticks independently of the game state machine
    // and force-starts the match when the stock PendingMatch state never
    // does (e.g. no human players on a dedicated server).
    if (Role == ROLE_Authority)
    {
        bDriverActive = (Spawn(class'MonsterArmyDriver') != None);
        if (!bDriverActive)
            log("MonsterArmy: could not spawn war driver - falling back to state timer", 'MonsterArmyV1');
    }
}

function CollectStartSpots()
{
    local PlayerStart P;
    StartSpots.Length = 0;
    foreach AllActors(class'PlayerStart', P)
    {
        // Skip vehicle spawn points (ONSPlayerStart) - spawning an army in
        // vehicle bays is asking for stuck monsters. The class name check
        // keeps us free of a compile-time dependency on the Onslaught
        // package.
        if (InStr(string(P.Class), "ONSPlayerStart") != -1)
            continue;
        StartSpots[StartSpots.Length] = P;
    }
    // Safety: some maps only have ONSPlayerStarts - use everything then.
    if (StartSpots.Length == 0)
        foreach AllActors(class'PlayerStart', P)
            StartSpots[StartSpots.Length] = P;
}

//------------------------------------------------------------------------------
// ONS map filtering
//------------------------------------------------------------------------------

function string GetCurrentMapName()
{
    local string S;
    S = string(Level);
    if (InStr(S, ".") != -1)
        S = Left(S, InStr(S, "."));
    return S;
}

function bool IsSupportedMap(string MapName)
{
    local string M;
    M = Caps(MapName);
    if (Left(M, 4) == "ONS-")
        return true;
    if (!bOnlyONSMaps)
        return true;
    return IsInCuratedList(M);
}

function bool IsInCuratedList(string MapName)
{
    local class<MapList> MLClass;
    local array<string> Maps;
    local int i;

    MLClass = class<MapList>(DynamicLoadObject(MapListType, class'Class'));
    if (MLClass == None)
        return true;
    Maps = MLClass.static.StaticGetMaps();
    for (i = 0; i < Maps.Length; i++)
        if (Caps(Maps[i]) == MapName)
            return true;
    return false;
}

function BuildFirstSupportedMap()
{
    local class<MapList> MLClass;
    local array<string> Maps;

    MLClass = class<MapList>(DynamicLoadObject(MapListType, class'Class'));
    if (MLClass == None)
        return;
    Maps = MLClass.static.StaticGetMaps();
    if (Maps.Length > 0)
        FirstSupportedMap = Maps[0];
}

function CheckCurrentMap()
{
    local string Cur;
    Cur = GetCurrentMapName();
    if (!IsSupportedMap(Cur))
    {
        if (FirstSupportedMap == "")
            FirstSupportedMap = "ONS-Torlan";
        log("MonsterArmy: map '" $ Cur $ "' is not an Onslaught battlefield, switching to '" $ FirstSupportedMap $ "'", 'MonsterArmyV1');
        Broadcast(Self, "THIS ISN'T AN ONSLAUGHT BATTLEFIELD - SWITCHING ARENAS...", 'CriticalEvent');
        bMapSwitchPending = true;
        MapSwitchClock = 5.0;
    }
}

function SwitchMap()
{
    bMapSwitchPending = false;
    if (FirstSupportedMap != "")
        Level.ServerTravel(FirstSupportedMap, false);
}

//==============================================================================
// Login / spectator enforcement
//==============================================================================

event PlayerController Login(string Portal, string Options, out string Error)
{
    local PlayerController PC;

    // Join as a NORMAL player, not a pure spectator (pure spectators are
    // excluded from the map vote). PostLogin locks them into the spectator
    // camera instead - the same trick MonsterFightClubV1 uses.
    PC = Super.Login(Portal, Options, Error);
    if (PC != None && PC.PlayerReplicationInfo != None)
        PC.ClientMessage("Welcome to the Monster Army arena! Grab some popcorn - the armies are fighting.");
    return PC;
}

event PostLogin(PlayerController NewPlayer)
{
    Super.PostLogin(NewPlayer);
    if (NewPlayer == None)
        return;
    NewPlayer.GotoState('Spectating');
    if (NewPlayer.PlayerReplicationInfo != None)
        log("MonsterArmy: " $ NewPlayer.PlayerReplicationInfo.PlayerName $ " is spectating", 'MonsterArmyV1');
}

function bool AllowBecomeActivePlayer(PlayerController P)
{
    return false;   // the audience never joins the fight
}

function bool BecomeSpectator(PlayerController P)
{
    return true;
}

// The stock spectator camera cycles view targets through this. Allow the
// monsters (the show) to be viewed, plus other real players.
function bool CanSpectate(PlayerController Viewer, bool bOnlySpectator, actor ViewTarget)
{
    local Controller C;

    if (ViewTarget == None)
        return false;
    C = Controller(ViewTarget);
    if (C != None)
    {
        if (C.Pawn != None && Monster(C.Pawn) != None)
            return true;   // the armies are always viewable
        if (C.Pawn != None && C.PlayerReplicationInfo != None && !C.PlayerReplicationInfo.bOnlySpectator)
            return true;
        return false;
    }
    return true;
}

function RestartPlayer(Controller aPlayer)
{
    // Nobody gets a pawn - this is a spectator war.
}

// No audience bots - the show runs on monsters alone.
function bool NeedPlayers()
{
    return false;
}

function bool TooManyBots(Controller botToRemove)
{
    return false;
}

//==============================================================================
// War flow
//==============================================================================

function StartMatch()
{
    Super.StartMatch();
    StartShow();
}

function StartShow()
{
    if (bShowStarted)
        return;
    bShowStarted = true;
    Phase = PHASE_IDLE;

    // The war clock starts NOW - RemainingTime used to count from server
    // boot, which ended the show a couple of minutes early (map load +
    // startup wait).
    RemainingTime = 60 * TimeLimit;
    if (GameReplicationInfo != None)
        GameReplicationInfo.RemainingTime = RemainingTime;

    DebugWrite("startshow");
    StartNewMatchup();
}

function StartNewMatchup()
{
    MatchupNumber++;
    RoundNumber = 1;
    RoundWins[0] = 0;
    RoundWins[1] = 0;
    PickArmies();
    Broadcast(Self, "NEXT BATTLE: " $ ArmySize $ " " $ Caps(ArmyAName) $ " VS " $ ArmySize $ " " $ Caps(ArmyBName) $ "!", 'CriticalEvent');
    log("MonsterArmy: matchup " $ MatchupNumber $ " - " $ ArmySize $ " " $ ArmyAName $ " vs " $ ArmySize $ " " $ ArmyBName, 'MonsterArmyV1');
    UpdateGRI();
    StartRound();
}

// Pick two random army classes from the monster table. The same armies
// fight every round of the matchup; a new matchup books fresh armies.
function PickArmies()
{
    local array<int> Idx;
    local int a, b, tries, i;
    local string AClass, AName, BClass, BName;
    local class<Monster> ALoaded, BLoaded;

    BuildMonsterIndex(Idx);
    if (Idx.Length == 0)
    {
        // Absolute fallback: the vanilla roster
        ArmyAClass = class'SkaarjPack.Skaarj';
        ArmyBClass = class'SkaarjPack.Gasbag';
        ArmyAName = "Skaarj";
        ArmyBName = "Gasbag";
        return;
    }

    // Pick army A.
    a = Idx[Rand(Idx.Length)];
    AClass = class'MonsterArmyMonsters'.default.MonsterTable[a].MonsterClassName;
    AName = class'MonsterArmyMonsters'.default.MonsterTable[a].MonsterName;
    ALoaded = class<Monster>(DynamicLoadObject(AClass, class'Class'));
    if (ALoaded == None)
        ALoaded = class'SkaarjPack.Skaarj';

    // Pick army B - any entry EXCEPT the exact one army A got.
    b = -1;
    for (tries = 0; tries < 40 && b == -1; tries++)
    {
        i = Idx[Rand(Idx.Length)];
        BClass = class'MonsterArmyMonsters'.default.MonsterTable[i].MonsterClassName;
        BLoaded = class<Monster>(DynamicLoadObject(BClass, class'Class'));
        if (BLoaded == None)
            continue;
        if (i == a && Idx.Length > 1)
            continue;
        b = i;
    }

    // Fallback: the whole table is broken - take the next index anyway.
    if (b == -1)
    {
        b = a;
        BClass = class'MonsterArmyMonsters'.default.MonsterTable[b].MonsterClassName;
        BName = class'MonsterArmyMonsters'.default.MonsterTable[b].MonsterName;
    }
    else
        BName = class'MonsterArmyMonsters'.default.MonsterTable[b].MonsterName;

    ArmyAClass = ALoaded;
    ArmyAName = AName;
    ArmyBClass = class<Monster>(DynamicLoadObject(BClass, class'Class'));
    if (ArmyBClass == None)
        ArmyBClass = class'SkaarjPack.Gasbag';
    ArmyBName = BName;
}

function BuildMonsterIndex(out array<int> Idx)
{
    local int i;
    local class<Monster> M;
    for (i = 0; i < class'MonsterArmyMonsters'.default.MonsterTable.Length; i++)
    {
        if (class'MonsterArmyMonsters'.default.MonsterTable[i].MonsterClassName == "")
            continue;
        M = class<Monster>(DynamicLoadObject(class'MonsterArmyMonsters'.default.MonsterTable[i].MonsterClassName, class'Class'));
        if (M != None)
            Idx[Idx.Length] = i;
    }
}

function StartRound()
{
    Phase = PHASE_FIGHT;
    PhaseClock = 0;
    bSpawnWindowOpen = true;
    SpawnWindowTicks = 0;

    SpawnArmies();
    PlayBellSound();
    Broadcast(Self, "ROUND " $ RoundNumber $ " OF " $ RoundsPerMatch $ ": " $ ArmySize $ " " $ Caps(ArmyAName) $ " VS " $ ArmySize $ " " $ Caps(ArmyBName) $ " - FIGHT!", 'CriticalEvent');
    UpdateGRI();
}

// Rings the bell for every connected viewer when the round starts.
function PlayBellSound()
{
    local Controller C;
    local PlayerController PC;

    if (!bBell || BellSound == None)
        return;
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        PC = PlayerController(C);
        if (PC != None)
            PC.ClientPlaySound(BellSound, false, BellVolume);
    }
}

//==============================================================================
// Armies
//==============================================================================

// Split the map's player starts into two clusters around the FARTHEST
// apart pair of starts, so the armies begin on opposite sides of the
// battlefield.
function bool GetArmyClusters(out array<int> CA, out array<int> CB)
{
    local int i, j, bi, bj;
    local float d, best;

    if (StartSpots.Length < 2)
        return false;

    best = -1;
    bi = 0;
    bj = 1;
    for (i = 0; i < StartSpots.Length; i++)
        for (j = i + 1; j < StartSpots.Length; j++)
        {
            d = VSize(StartSpots[i].Location - StartSpots[j].Location);
            if (d > best)
            {
                best = d;
                bi = i;
                bj = j;
            }
        }

    CA.Length = 0;
    CB.Length = 0;
    for (i = 0; i < StartSpots.Length; i++)
    {
        if (i == bi
            || VSize(StartSpots[i].Location - StartSpots[bi].Location)
               <= VSize(StartSpots[i].Location - StartSpots[bj].Location))
            CA[CA.Length] = i;
        else
            CB[CB.Length] = i;
    }
    if (CB.Length == 0)
        CB[CB.Length] = bj;   // safety - never leave army B without a spot
    return (CA.Length > 0 && CB.Length > 0);
}

function bool SpawnArmies()
{
    local array<int> CA, CB;
    local int NA, NB;

    DestroyArmies();
    if (GetArmyClusters(CA, CB))
    {
        ArmyClusterA = CA;
        ArmyClusterB = CB;
        NA = SpawnArmyMonsters(0, CA, ArmyAClass, ArmySize);
        NB = SpawnArmyMonsters(1, CB, ArmyBClass, ArmySize);
    }
    else
    {
        // Weird map with almost no starts - drop both armies at the center.
        ArmyClusterA.Length = 0;
        ArmyClusterB.Length = 0;
        NA = SpawnArmyAtCenter(0, ArmyAClass);
        NB = SpawnArmyAtCenter(1, ArmyBClass);
    }

    if (NA + NB == 0)
    {
        log("MonsterArmy: could not spawn any monsters - will top up", 'MonsterArmyV1');
        return false;
    }
    UpdateAliveCounts();   // fresh counts BEFORE the first top-up tick
    LinkArmies();
    return true;
}

// During the spawn window (first ~10 seconds of a round) keep spawning
// until both armies are full - covers failed initial spawns.
function TopUpArmies()
{
    local int NeedA, NeedB;

    if (AliveA < ArmySize)
    {
        NeedA = ArmySize - AliveA;
        if (ArmyClusterA.Length > 0)
            SpawnArmyMonsters(0, ArmyClusterA, ArmyAClass, NeedA);
        else
            SpawnArmyAtCenter(0, ArmyAClass);
    }
    if (AliveB < ArmySize)
    {
        NeedB = ArmySize - AliveB;
        if (ArmyClusterB.Length > 0)
            SpawnArmyMonsters(1, ArmyClusterB, ArmyBClass, NeedB);
        else
            SpawnArmyAtCenter(1, ArmyBClass);
    }
    LinkArmies();
}

function int SpawnArmyMonsters(int Team, array<int> Cluster, class<Monster> MClass, int Count)
{
    local int i, k, Spot, Spawned;
    local Monster M;
    local vector Loc;
    local float A, R;

    for (i = 0; i < Count; i++)
    {
        M = None;
        // Try every cluster spot (round-robin) with a random scatter offset
        // so the army fans out instead of stacking on one start.
        for (k = 0; k < Cluster.Length && M == None; k++)
        {
            Spot = Cluster[(i + k) % Cluster.Length];
            A = FRand() * 2 * Pi;
            R = 150 + FRand() * 300;
            Loc = StartSpots[Spot].Location;
            Loc.X += R * Cos(A);
            Loc.Y += R * Sin(A);
            Loc.Z += 30;
            M = Spawn(MClass,,, Loc, StartSpots[Spot].Rotation);
        }
        // Last resort: the plain start location.
        if (M == None)
        {
            Spot = Cluster[i % Cluster.Length];
            M = Spawn(MClass,,, StartSpots[Spot].Location, StartSpots[Spot].Rotation);
        }
        if (M != None)
        {
            SetupArmyMonster(M, Team);
            Spawned++;
        }
    }
    return Spawned;
}

function int SpawnArmyAtCenter(int Team, class<Monster> MClass)
{
    local int i, Spawned;
    local Monster M;
    local vector Center, Loc;
    local float A, R;

    Center = GetLevelCenter();
    for (i = 0; i < ArmySize; i++)
    {
        A = FRand() * 2 * Pi;
        R = 200 + FRand() * 500;
        Loc = Center;
        Loc.X += R * Cos(A);
        Loc.Y += R * Sin(A);
        Loc.Z += 60;
        M = Spawn(MClass,,, Loc);
        if (M != None)
        {
            SetupArmyMonster(M, Team);
            Spawned++;
        }
    }
    return Spawned;
}

// Spawn the monster's grudge controller, possess it and tag the team.
function Monster SetupArmyMonster(Monster M, int Team)
{
    local MonsterArmyMonsterController C;

    if (M == None)
        return None;

    M.DeactivateSpawnProtection();
    M.HealthMax = M.Health;

    // Pawns don't auto-spawn controllers in this engine - spawn and
    // possess like TitanRPG does. Always use OUR controller so the army
    // never camps and team assignment stays reliable.
    if (M.Controller != None)
        M.Controller.Destroy();
    C = Spawn(class'MonsterArmyMonsterController');
    if (C != None)
    {
        C.Possess(M);
        C.InitializeSkill(7.0);
        C.Team = Team;
        C.WhatToDoNext(1);
    }
    if (Team == 0)
        ArmyA[ArmyA.Length] = M;
    else
        ArmyB[ArmyB.Length] = M;
    return M;
}

function vector GetLevelCenter()
{
    local int i;
    local vector C;
    if (StartSpots.Length == 0)
        return vect(0, 0, 200);
    for (i = 0; i < StartSpots.Length; i++)
        C += StartSpots[i].Location;
    C /= StartSpots.Length;
    C.Z += 120;
    return C;
}

// Point every monster at the nearest living enemy.
function LinkArmies()
{
    local int i;
    local Monster M, Enemy;
    local MonsterArmyMonsterController C;

    for (i = 0; i < ArmyA.Length; i++)
    {
        M = ArmyA[i];
        if (M == None || M.Health <= 0 || M.bDeleteMe)
            continue;
        Enemy = FindNearestEnemy(M, 0);
        if (Enemy == None)
            continue;
        C = MonsterArmyMonsterController(M.Controller);
        if (C != None && C.GrudgeEnemy != Enemy)
            C.SetGrudgeEnemy(Enemy);
    }
    for (i = 0; i < ArmyB.Length; i++)
    {
        M = ArmyB[i];
        if (M == None || M.Health <= 0 || M.bDeleteMe)
            continue;
        Enemy = FindNearestEnemy(M, 1);
        if (Enemy == None)
            continue;
        C = MonsterArmyMonsterController(M.Controller);
        if (C != None && C.GrudgeEnemy != Enemy)
            C.SetGrudgeEnemy(Enemy);
    }
}

function Monster FindNearestEnemy(Monster M, int Team)
{
    local Monster Best, E;
    local float bd, d;
    local int i;

    if (Team == 0)
    {
        for (i = 0; i < ArmyB.Length; i++)
        {
            E = ArmyB[i];
            if (E == None || E.Health <= 0 || E.bDeleteMe)
                continue;
            d = VSize(E.Location - M.Location);
            if (Best == None || d < bd)
            {
                Best = E;
                bd = d;
            }
        }
    }
    else
    {
        for (i = 0; i < ArmyA.Length; i++)
        {
            E = ArmyA[i];
            if (E == None || E.Health <= 0 || E.bDeleteMe)
                continue;
            d = VSize(E.Location - M.Location);
            if (Best == None || d < bd)
            {
                Best = E;
                bd = d;
            }
        }
    }
    return Best;
}

// Per-second army supervision: controllers, grudges, stuck recovery,
// visibility, and cleanup of strays.
function EnforceArmies()
{
    local int i;

    for (i = 0; i < ArmyA.Length; i++)
        EnforceArmyMonster(ArmyA[i], 0);
    for (i = 0; i < ArmyB.Length; i++)
        EnforceArmyMonster(ArmyB[i], 1);

    DestroyStrayMonsters();
}

function EnforceArmyMonster(Monster M, int Team)
{
    local Monster Enemy;
    local MonsterArmyMonsterController C;

    if (M == None || M.Health <= 0 || M.bDeleteMe)
        return;
    Enemy = FindNearestEnemy(M, Team);
    if (Enemy == None)
        return;   // the other army is gone - the round ends this tick

    C = MonsterArmyMonsterController(M.Controller);
    if (C == None)
    {
        // The controller died or never spawned - rebuild it.
        if (M.Controller != None)
            M.Controller.Destroy();
        C = Spawn(class'MonsterArmyMonsterController');
        if (C == None)
            return;
        C.Possess(M);
        C.InitializeSkill(7.0);
        C.Team = Team;
    }

    if (C.GrudgeEnemy != Enemy)
    {
        C.SetGrudgeEnemy(Enemy);
        C.WhatToDoNext(1);
    }
    else if (C.Enemy == None)
    {
        C.Enemy = Enemy;
        C.Target = Enemy;
        C.WhatToDoNext(1);
    }

    // Never let the army camp - kick resting monsters back into the fight.
    if (C.GetStateName() == 'RestFormation')
    {
        C.GotoState('Charging');
        C.WhatToDoNext(1);
    }

    // Hide checks: some packs hide their pawn mid-fight - force visible.
    if (M.bHidden)
    {
        M.bHidden = false;
        M.SetInvisibility(0.0);
    }

    // Far away from every enemy with no fight going on - pull them in.
    if (VSize(M.Location - Enemy.Location) > 3000)
        C.TeleportNextToEnemy();
}

// Destroy every Monster in the level that isn't in one of the armies -
// pack minions and map strays must not join the war.
function DestroyStrayMonsters()
{
    local Monster M;
    local Controller C;

    foreach DynamicActors(class'Monster', M)
    {
        if (IsArmyMonster(M))
            continue;
        C = M.Controller;
        if (C != None && PlayerController(C) == None)
            C.Destroy();
        M.Destroy();
    }
}

function bool IsArmyMonster(Monster M)
{
    local int i;
    if (M == None)
        return false;
    for (i = 0; i < ArmyA.Length; i++)
        if (ArmyA[i] == M)
            return true;
    for (i = 0; i < ArmyB.Length; i++)
        if (ArmyB[i] == M)
            return true;
    return false;
}

// Team lookup for damage checks. Our controller knows its team; monsters
// without one (strays) are -1 = enemy of everyone.
function int GetMonsterTeam(Pawn P)
{
    local MonsterArmyMonsterController C;
    local int i;

    if (P == None)
        return -1;
    C = MonsterArmyMonsterController(P.Controller);
    if (C != None)
        return C.Team;
    for (i = 0; i < ArmyA.Length; i++)
        if (ArmyA[i] == P)
            return 0;
    for (i = 0; i < ArmyB.Length; i++)
        if (ArmyB[i] == P)
            return 1;
    return -1;
}

function DestroyArmies()
{
    local int i;
    local Monster M;
    local array<MonsterArmyMonsterController> Ghosts;
    local MonsterArmyMonsterController G;

    for (i = 0; i < ArmyA.Length; i++)
    {
        M = ArmyA[i];
        if (M != None)
        {
            if (M.Controller != None)
                M.Controller.Destroy();
            M.Destroy();
        }
    }
    for (i = 0; i < ArmyB.Length; i++)
    {
        M = ArmyB[i];
        if (M != None)
        {
            if (M.Controller != None)
                M.Controller.Destroy();
            M.Destroy();
        }
    }
    ArmyA.Length = 0;
    ArmyB.Length = 0;
    AliveA = 0;
    AliveB = 0;

    // Sweep ghost controllers (pawns died outside the kill path).
    foreach AllActors(class'MonsterArmyMonsterController', G)
        if (G.Pawn == None)
            Ghosts[Ghosts.Length] = G;
    for (i = 0; i < Ghosts.Length; i++)
    {
        G = Ghosts[i];
        if (G != None)
            G.Destroy();
    }
}

//==============================================================================
// Combat events
//==============================================================================

function Killed(Controller Killer, Controller Killed, Pawn KilledPawn, class<DamageType> damageType)
{
    local Monster M;

    M = Monster(KilledPawn);
    if (M != None && IsArmyMonster(M))
    {
        // Free the dead monster's controller so it doesn't roam as a ghost.
        if (M.Controller != None)
            M.Controller.Destroy();
    }
    Super.Killed(Killer, Killed, KilledPawn, damageType);
}

function BroadcastDeathMessage(Controller Killer, Controller Other, class<DamageType> damageType)
{
    if (MonsterController(Killer) != None || MonsterController(Other) != None)
        return;   // monster deaths are covered by the round announcements
    Super.BroadcastDeathMessage(Killer, Other, damageType);
}

function int ReduceDamage(int Damage, pawn injured, pawn instigatedBy, vector HitLocation, out vector Momentum, class<DamageType> DamageType)
{
    local int TI, TS;

    if (bLogDamage && Monster(injured) != None)
        log("MA-DMG: " $ instigatedBy $ " -> " $ injured
            $ " dmg=" $ Damage $ " type=" $ DamageType $ " hp=" $ injured.Health, 'MonsterArmyV1');

    // Friendly fire off: army monsters never damage their own army.
    if (Monster(injured) != None && Monster(instigatedBy) != None)
    {
        TI = GetMonsterTeam(injured);
        TS = GetMonsterTeam(instigatedBy);
        if (TI >= 0 && TI == TS)
            return 0;
    }
    return Super.ReduceDamage(Damage, injured, instigatedBy, HitLocation, Momentum, DamageType);
}

//==============================================================================
// Round flow
//==============================================================================

function UpdateAliveCounts()
{
    local int i, n;

    n = 0;
    for (i = 0; i < ArmyA.Length; i++)
        if (ArmyA[i] != None && ArmyA[i].Health > 0 && !ArmyA[i].bDeleteMe)
            n++;
    AliveA = n;
    n = 0;
    for (i = 0; i < ArmyB.Length; i++)
        if (ArmyB[i] != None && ArmyB[i].Health > 0 && !ArmyB[i].bDeleteMe)
            n++;
    AliveB = n;

    if (MAGRI != None && (MAGRI.AliveA != AliveA || MAGRI.AliveB != AliveB))
    {
        MAGRI.AliveA = AliveA;
        MAGRI.AliveB = AliveB;
        MAGRI.NetUpdateTime = Level.TimeSeconds - 1;
    }
}

// Winner: 0 = draw, 1 = army A, 2 = army B.
function EndRound(int Winner, optional bool bTimedOut)
{
    local string Msg;

    if (Phase != PHASE_FIGHT)
        return;

    Phase = PHASE_RESULT;
    PhaseClock = 0;

    if (Winner == 0)
    {
        if (bTimedOut)
            Msg = "TIME! ROUND " $ RoundNumber $ " IS A DRAW - " $ AliveA $ "-" $ AliveB $ " ARMIES REMAIN!";
        else
            Msg = "ROUND " $ RoundNumber $ " IS A DRAW - BOTH ARMIES DESTROYED!";
    }
    else
    {
        RoundWins[Winner - 1]++;
        TotalWins[Winner - 1]++;
        if (bTimedOut)
            Msg = "TIME! ROUND " $ RoundNumber $ " GOES TO ARMY " $ GetArmyLetter(Winner)
                  $ " (" $ Caps(GetArmyName(Winner)) $ ") - " $ GetAlive(Winner) $ " MONSTERS STILL STAND!";
        else
            Msg = "ARMY " $ GetArmyLetter(Winner) $ " (" $ Caps(GetArmyName(Winner))
                  $ ") WIPES OUT THE ENEMY ARMY - ROUND " $ RoundNumber $ " WON!";
    }
    Broadcast(Self, Msg, 'CriticalEvent');
    Broadcast(Self, "MATCH SCORE: " $ RoundWins[0] $ "-" $ RoundWins[1], 'CriticalEvent');
    log("MonsterArmy: round " $ RoundNumber $ " -> winner " $ Winner $ " (score " $ RoundWins[0] $ "-" $ RoundWins[1] $ ")", 'MonsterArmyV1');

    RoundNumber++;
    UpdateGRI();
    DebugWrite("roundend winner=" $ Winner $ " round=" $ (RoundNumber - 1));
}

function TimeoutRound()
{
    local int W;

    if (Phase != PHASE_FIGHT)
        return;
    if (AliveA == AliveB)
        W = 0;
    else if (AliveA > AliveB)
        W = 1;
    else
        W = 2;
    EndRound(W, true);
}

function int GetAlive(int Army)
{
    if (Army == 1)
        return AliveA;
    return AliveB;
}

function string GetArmyLetter(int Army)
{
    if (Army == 2)
        return "B";
    return "A";
}

function string GetArmyName(int Army)
{
    if (Army == 2)
        return ArmyBName;
    return ArmyAName;
}

function AdvanceRound()
{
    local int Target;
    Target = (RoundsPerMatch + 1) / 2;

    if (RoundWins[0] >= Target || RoundWins[1] >= Target || RoundNumber > RoundsPerMatch)
        BeginIntermission();
    else
        StartRound();
}

function BeginIntermission()
{
    Phase = PHASE_INTERMISSION;
    PhaseClock = 0;

    if (RoundWins[0] == RoundWins[1])
        Broadcast(Self, "THE MATCHUP ENDS IN A DRAW " $ RoundWins[0] $ "-" $ RoundWins[1] $ " - NEW ARMIES WILL BE CHOSEN!", 'CriticalEvent');
    else if (RoundWins[0] > RoundWins[1])
        Broadcast(Self, "ARMY A (" $ Caps(ArmyAName) $ ") TAKES THE MATCHUP " $ RoundWins[0] $ "-" $ RoundWins[1] $ "!", 'CriticalEvent');
    else
        Broadcast(Self, "ARMY B (" $ Caps(ArmyBName) $ ") TAKES THE MATCHUP " $ RoundWins[1] $ "-" $ RoundWins[0] $ "!", 'CriticalEvent');

    DestroyArmies();
    UpdateGRI();
}

//==============================================================================
// War driver - the MonsterArmyDriver actor calls RoundTick() once per
// second, independent of the game state machine. The state override below
// is only a fallback in case the driver could not spawn.
//==============================================================================

state MatchInProgress
{
    function Timer()
    {
        // The STOCK time-limit clock: decrements RemainingTime every game
        // second and fires EndGame("TimeLimit") at zero - the same clock
        // the HUD displays.
        Super.Timer();
        RoundTick();
    }
}

auto state PendingMatch
{
    function Timer()
    {
        Super.Timer();
    }
}

function bool ShowHasStarted()
{
    return (Phase != PHASE_IDLE);
}

function RoundTick()
{
    local int TimeLeft;

    if (Role != ROLE_Authority || bGameEnded || bShowEnded)
        return;

    PhaseClock += 1;

    // live state telemetry - visible in System\MonsterArmyV1.ini
    StatusClock += 1;
    if (StatusClock >= 5)
    {
        StatusClock = 0;
        WriteDebugStatus();
    }

    if (bMapSwitchPending)
    {
        MapSwitchClock -= 1;
        if (MapSwitchClock <= 0)
            SwitchMap();
    }

    switch (Phase)
    {
        case PHASE_FIGHT:
            // Fresh alive counts first - the top-up must never see the
            // stale 0 from round start (that double-spawned whole armies).
            UpdateAliveCounts();
            // The spawn window keeps topping the armies up to full size
            // for the first ~10 seconds of the round, then it's a
            // fight-to-the-death - no mid-round respawns.
            if (bSpawnWindowOpen)
            {
                SpawnWindowTicks++;
                TopUpArmies();
                if (SpawnWindowTicks >= 10 || (AliveA >= ArmySize && AliveB >= ArmySize))
                    bSpawnWindowOpen = false;
            }
            EnforceArmies();
            UpdateAliveCounts();
            if (AliveA == 0 && AliveB == 0)
                EndRound(0);
            else if (AliveA == 0)
                EndRound(2);
            else if (AliveB == 0)
                EndRound(1);
            else if (PhaseClock >= RoundTimeLimit)
                TimeoutRound();
            break;

        case PHASE_RESULT:
            if (PhaseClock >= ResultTime)
                AdvanceRound();
            break;

        case PHASE_INTERMISSION:
            if (PhaseClock >= IntermissionTime)
                StartNewMatchup();
            break;
    }

    // replicated countdown for the HUD
    if (MAGRI != None)
    {
        switch (Phase)
        {
            case PHASE_FIGHT:       TimeLeft = Max(0, RoundTimeLimit - int(PhaseClock)); break;
            case PHASE_RESULT:      TimeLeft = Max(0, int(ResultTime - PhaseClock));    break;
            case PHASE_INTERMISSION:TimeLeft = Max(0, int(IntermissionTime - PhaseClock)); break;
            default:                TimeLeft = 0; break;
        }
        if (MAGRI.PhaseTimeLeft != TimeLeft)
        {
            MAGRI.PhaseTimeLeft = TimeLeft;
            MAGRI.NetUpdateTime = Level.TimeSeconds - 1;
        }
    }
}

// The round the HUD should show. RoundNumber is incremented at round END,
// so during RESULT and INTERMISSION it already points at the NEXT round.
function int GetDisplayRound()
{
    if (Phase == PHASE_RESULT || Phase == PHASE_INTERMISSION)
        return Max(1, RoundNumber - 1);
    return RoundNumber;
}

function UpdateGRI()
{
    if (MAGRI == None)
        return;
    MAGRI.Phase = Phase;
    MAGRI.RoundNumber = Min(GetDisplayRound(), RoundsPerMatch);
    MAGRI.MatchupNumber = MatchupNumber;
    MAGRI.RoundWinsA = RoundWins[0];
    MAGRI.RoundWinsB = RoundWins[1];
    MAGRI.ArmyAName = ArmyAName;
    MAGRI.ArmyBName = ArmyBName;
    MAGRI.NetUpdateTime = Level.TimeSeconds - 1;
}

// Admin-friendly periodic status line
function WriteDebugStatus()
{
    local string S;

    S = "phase=" $ Phase $ " round=" $ RoundNumber $ " matchups=" $ MatchupNumber;
    if (ArmyAClass != None)
        S = S $ " armyA=" $ ArmyAName $ ":" $ AliveA;
    else
        S = S $ " armyA=none";
    if (ArmyBClass != None)
        S = S $ " armyB=" $ ArmyBName $ ":" $ AliveB;
    else
        S = S $ " armyB=none";
    S = S $ " score=" $ RoundWins[0] $ "-" $ RoundWins[1] $ " total=" $ TotalWins[0] $ "-" $ TotalWins[1];

    // silent ini telemetry only - no log spam
    default.DebugStatus = S;
    StaticSaveConfig();
}

function DebugWrite(string S)
{
    default.DebugStatus = S;
    StaticSaveConfig();
    log("MonsterArmy: " $ S, 'MonsterArmyV1');
}

//==============================================================================
// Match end - the show must NOT restart the level when it ends (that would
// boot the audience). Override RestartGame to keep the server on the map.
//==============================================================================

function EndGame(PlayerReplicationInfo Winner, string Reason)
{
    local int W;

    // The war ONLY ends on the time limit.
    if (Reason ~= "ScoreLimit" || Reason ~= "KillLimit" || Reason ~= "FragLimit")
        return;
    if (bShowEnded)
        return;
    bShowEnded = true;

    Phase = PHASE_INTERMISSION;
    if (MAGRI != None)
    {
        MAGRI.bShowEnded = true;
        MAGRI.Phase = PHASE_INTERMISSION;
        MAGRI.NetUpdateTime = Level.TimeSeconds - 1;
    }

    if (Reason ~= "TimeLimit")
    {
        if (TotalWins[0] > TotalWins[1])
            W = 1;
        else if (TotalWins[1] > TotalWins[0])
            W = 2;
        if (W != 0)
            Broadcast(Self, "SHOW'S OVER! ARMY " $ GetArmyLetter(W) $ " (" $ Caps(GetArmyName(W))
                      $ ") WINS THE WAR " $ TotalWins[0] $ "-" $ TotalWins[1] $ "!", 'CriticalEvent');
        else
            Broadcast(Self, "SHOW'S OVER! THE WAR ENDS TIED " $ TotalWins[0] $ "-" $ TotalWins[1] $ "!", 'CriticalEvent');
        log("MonsterArmy: show over - " $ TotalWins[0] $ "-" $ TotalWins[1], 'MonsterArmyV1');
    }
    Super.EndGame(Winner, Reason);
    DestroyArmies();
}

// The stock CheckEndGame rejects TIED team scores - and this war always
// has tied scores (nobody gets frags). When our war clock says it's over,
// the game must end, no questions asked.
function bool CheckEndGame(PlayerReplicationInfo Winner, string Reason)
{
    if (bShowEnded)
    {
        EndTime = Level.TimeSeconds + EndTimeDelay;
        return true;
    }
    return Super.CheckEndGame(Winner, Reason);
}

function PlayEndOfMatchMessage() { }

// Never change levels / restart - the Monster Army war is endless.
function RestartGame()
{
    if ((GameRulesModifiers != None) && GameRulesModifiers.HandleRestartGame())
        return;
    if (bGameRestarted)
        return;
    bGameRestarted = true;

    if (VotingHandler != None && !VotingHandler.HandleRestartGame())
        return;

    log("MonsterArmy: restart suppressed (war continues)", 'MonsterArmyV1');
}

//==============================================================================
// Defaults
//==============================================================================

defaultproperties
{
     ArmySize=32
     RoundTimeLimit=300
     RoundsPerMatch=3
     ResultTime=5.000000
     IntermissionTime=7.000000
     bOnlyONSMaps=True
     bBell=True
     BellVolume=255
     bLogDamage=False

     BellSound=sound'MonsterArmyV1.BellSound'

     MinPlayers=0
     MaxPlayers=32
     MaxSpectators=32
     TimeLimit=0          // 0 = endless war (matchups cycle forever)
     GoalScore=0

     GameName="Monster Army"
     Description="Two 32-monster armies fight to the death on Onslaught battlefields. Best-of-three rounds - wipe the enemy army, or hold the most monsters when time runs out!"
     Acronym="MAR"
     ScreenShotName="UT2004Thumbnails.DMShots"
     DecoTextName="MonsterArmyV1.MonsterArmyGame"
     BeaconName="MAR"

     HUDType="MonsterArmyV1.MonsterArmyHUD"
     MapListType="MonsterArmyV1.MapListMonsterArmy"
     MapPrefix="ONS"
     GameReplicationInfoClass=Class'MonsterArmyV1.MonsterArmyGRI'
     PlayerControllerClassName="MonsterArmyV1.MonsterArmyPlayerController"
}
