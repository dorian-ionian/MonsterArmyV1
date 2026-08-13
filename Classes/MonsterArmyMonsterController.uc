//=============================================================================
// MonsterArmyMonsterController
// Army grudge AI for the war's monsters. The stock MonsterController is
// designed for Invasion: it loses interest when the enemy is out of sight,
// camps in RestFormation after failed hunts, and stalls on pathfinding
// failures - which reads as "monsters not fighting".
//
// This controller never forgets its grudge (the nearest living enemy the
// game assigns), always charges, never camps, and self-recovers when stuck
// by teleporting next to its enemy. The Team var lets the game block
// friendly fire between army monsters.
//=============================================================================
class MonsterArmyMonsterController extends MonsterController;

var Pawn GrudgeEnemy;        // the assigned enemy - never forgotten
var int Team;                // 0 = army A, 1 = army B (set by the game)
var bool bPosTracked;        // stuck detection state
var vector TrackPos;         // last known position when entering Charging
var int StuckEntries;        // consecutive blocked re-entries
var int AnimWaitTicks;       // bounded bShotAnim wait in Charging
var float AttackStartHealth; // target health when a melee attack started
var int FallbackTicks;       // fallback damage attempts this attack

// Called by the game when the monster is assigned a new target. Direct
// assignment on purpose: the stock SetEnemy() refuses same-species
// monsters (SameSpeciesAs), so it would silently fail for many armies.
function SetGrudgeEnemy(Pawn Other)
{
    GrudgeEnemy = Other;
    if (GrudgeEnemy != None)
    {
        Enemy = GrudgeEnemy;
        Target = GrudgeEnemy;
    }
}

//------------------------------------------------------------------------------
// Grudge enforcement - every stock path that could drop the enemy or send
// the monster off to camp is intercepted and redirected back at the grudge.
//------------------------------------------------------------------------------

// A dead grudge is replaced IMMEDIATELY with the nearest living enemy of
// the opposing army (the game knows the rosters). This both keeps the
// monster fighting without a 1-second re-aim lag and keeps the stock AI
// states from ever seeing a None Enemy (which spams Accessed None).
function bool GrudgeAlive()
{
    if (GrudgeEnemy == None || GrudgeEnemy.Health <= 0 || GrudgeEnemy.bDeleteMe)
    {
        SetGrudgeEnemy(GetNextEnemy());
        return (GrudgeEnemy != None && GrudgeEnemy.Health > 0 && GrudgeEnemy.Controller != None);
    }
    return true;
}

function Pawn GetNextEnemy()
{
    local MonsterArmyGame G;
    local Monster M;

    if (Pawn == None || Level.Game == None)
        return None;
    G = MonsterArmyGame(Level.Game);
    if (G == None)
        return None;
    M = Monster(Pawn);
    if (M == None)
        return None;
    return G.FindNearestEnemy(M, Team);
}

// Stock version only considers *visible* pawns and can leave us enemy-less.
// With a live grudge we always have a target.
function bool FindNewEnemy()
{
    if (GrudgeAlive())
    {
        if (Enemy != GrudgeEnemy)
            ChangeEnemy(GrudgeEnemy, CanSee(GrudgeEnemy));
        return true;
    }
    return Super.FindNewEnemy();
}

// Re-assert the grudge before the stock decision logic runs.
function ExecuteWhatToDoNext()
{
    if (GrudgeAlive() && Enemy != GrudgeEnemy)
        Enemy = GrudgeEnemy;
    Super.ExecuteWhatToDoNext();
}

// The stock WanderOrCamp() leads to RestFormation camping - the exact
// "monsters not fighting" symptom. A live grudge always charges instead.
function WanderOrCamp(bool bMayCrouch)
{
    if (GrudgeAlive())
    {
        Enemy = GrudgeEnemy;
        GotoState('Charging');
        return;
    }
    Super.WanderOrCamp(bMayCrouch);
}

// Bypass the whole FightEnemy() tactical tree (stake-outs, failed-hunt
// hang-outs, "enemy not visible -> wander"): in range -> attack, otherwise
// -> charge at the enemy. The war must never stall.
function ChooseAttackMode()
{
    if (GrudgeAlive() && Enemy != GrudgeEnemy)
        Enemy = GrudgeEnemy;
    if (Enemy == None || Pawn == None)
        return;

    // NOTE: no CanAttack() gate here - that stock function is declared
    // without a body in Monster.uc and returns false for any monster that
    // doesn't override it, which silently blocked ALL attacks. Range is the
    // only check that matters.
    if (VSize(Enemy.Location - Pawn.Location)
        < Pawn.MeleeRange + Pawn.CollisionRadius + Enemy.CollisionRadius + 100)
        DoRangedAttackOn(Enemy);   // in striking range - attack
    else
        DoCharge();                // out of range - chase them down
}

// The stock DoCharge() routes water/non-walkers into the unguarded stock
// TacticalMove state, which reads Enemy without None checks (Accessed None
// spam once a grudge dies). Always charge instead - our Charging state
// self-recovers from any terrain with teleports.
function DoTacticalMove()
{
    GotoState('Charging');
}

//------------------------------------------------------------------------------
// RestFormation - the stock camping state. A live grudge never rests.
//------------------------------------------------------------------------------

state RestFormation
{
Begin:
    if (GrudgeAlive())
    {
        Enemy = GrudgeEnemy;
        GotoState('Charging');
    }
    else
    {
        // no enemy left (army wiped) - idle quietly instead of wandering
        WaitForLanding();
        Pawn.Acceleration = vect(0,0,0);
        Sleep(1.0);
        Goto('Begin');
    }
}

//------------------------------------------------------------------------------
// Charging - direct pursuit with stuck recovery. The stock version depends
// on pathfinding that can fail ("No pawn or goal for ActorReachable"), then
// silently strands the monster. Here the grudge is always the move target
// and blocked attempts trigger a teleport to the enemy's side.
//------------------------------------------------------------------------------

state Charging
{
ignores SeePlayer, HearNoise;

    function MayFall()
    {
        if (MoveTarget != Enemy)
            return;
        Pawn.bCanJump = ActorReachable(Enemy);
        if (!Pawn.bCanJump)
            MoveTimer = -1.0;
    }

    event bool NotifyBump(actor Other)
    {
        if (Other == Enemy || Other == GrudgeEnemy)
        {
            if (Enemy == None)
                Enemy = GrudgeEnemy;
            if (Enemy != None)
                DoRangedAttackOn(Enemy);
            return false;
        }
        return Global.NotifyBump(Other);
    }

    function Timer()
    {
        enable('NotifyBump');
        Target = Enemy;
        TimedFireWeaponAtEnemy();
    }

    function EnemyNotVisible()
    {
        // losing sight never ends the chase - the grudge is still out there
        if (GrudgeAlive())
        {
            Enemy = GrudgeEnemy;
            GotoState('Charging');
        }
        else
            WhatToDoNext(15);
    }

    function EndState()
    {
        if ((Pawn != None) && Pawn.JumpZ > 0)
            Pawn.bCanJump = true;
    }

    // The stock version reads Enemy.Location without a None check - the
    // grudge can die mid-fight, which spammed Accessed None. Guard it.
    function bool StrafeFromDamage(float Damage, class<DamageType> DamageType, bool bFindDest)
    {
        if (Enemy == None || Pawn == None)
            return false;
        return Super.StrafeFromDamage(Damage, DamageType, bFindDest);
    }

    // The stock TryStrafe detours into the unguarded stock TacticalMove
    // state (DoStrafeMove), which reads Enemy without None checks. Skip the
    // detour - the monster simply keeps charging.
    function bool TryStrafe(vector sideDir)
    {
        return true;
    }

Begin:
    if (Pawn.Physics == PHYS_Falling && Enemy != None)
    {
        Focus = Enemy;
        Destination = Enemy.Location;
        WaitForLanding();
    }
    if (GrudgeAlive() && Enemy != GrudgeEnemy)
        Enemy = GrudgeEnemy;
    if (Enemy == None)
    {
        // no enemy left - idle briefly instead of hot-looping
        WaitForLanding();
        Pawn.Acceleration = vect(0,0,0);
        Sleep(0.5);
        Goto('Begin');
    }
WaitForAnim:
    if (Monster(Pawn).bShotAnim)
    {
        Sleep(0.35);
        // Bounded wait: some packs' attack anims never end under a foreign
        // controller - a stuck bShotAnim would freeze the monster forever.
        // After ~2 seconds, force-move anyway.
        AnimWaitTicks++;
        if (AnimWaitTicks < 6)
            Goto('WaitForAnim');
        AnimWaitTicks = 0;
        Monster(Pawn).bShotAnim = false;
    }

    // Stuck detection: each blocked MoveToward returns immediately, so
    // consecutive re-entries without real movement mean we're jammed.
    if (bPosTracked && VSize(Pawn.Location - TrackPos) < 120)
    {
        StuckEntries++;
        if (StuckEntries >= 3)
        {
            StuckEntries = 0;
            TeleportNextToEnemy();
        }
    }
    else
    {
        StuckEntries = 0;
        bPosTracked = true;
        TrackPos = Pawn.Location;
    }

    // Pathfinding first (looks natural), direct pursuit as fallback. Either
    // way the enemy is the target - we never wander off to camp.
    if (!FindBestPathToward(Enemy, false, true))
        MoveTarget = Enemy;

Moving:
    MoveToward(MoveTarget, FaceActor(1), 1.0);

    // in striking range - stop and attack instead of milling about
    // (range-only check; CanAttack() is a no-op bodyless declaration that
    // would block attacks for most custom monsters)
    if (Enemy != None && VSize(Enemy.Location - Pawn.Location)
        < Pawn.MeleeRange + Pawn.CollisionRadius + Enemy.CollisionRadius + 100)
        DoRangedAttackOn(Enemy);

    WhatToDoNext(17);
    Goto('Begin');
}

//------------------------------------------------------------------------------
// RangedAttack - the stock firing loop, which every monster pack was built
// to work with: it paces ranged attacks properly (focus check, RangedAttack-
// Time, bShotAnim handling between shots) and triggers melee attack anims
// for melee monsters. PLUS a damage fallback timer for packs whose
// RangedAttack is a no-op (Dinotopia, KF, ...): if the target's health
// isn't dropping, deal direct MeleeDamageTarget damage while in range.
//------------------------------------------------------------------------------

state RangedAttack
{
ignores SeePlayer, HearNoise, Bump;

    function BeginState()
    {
        StopStartTime = Level.TimeSeconds;
        bHasFired = false;
        if (Pawn != None)
            Pawn.Acceleration = vect(0,0,0);
        if (Target == None)
            Target = Enemy;

        // Debug AI trace (only when bLogDamage is enabled in the ini).
        if (class'MonsterArmyGame'.default.bLogDamage)
        {
            log("MA-AI: " $ Pawn $ " state=" $ GetStateName() $ " enemy=" $ Enemy
                $ " dist=" $ int(VSize(Enemy.Location - Pawn.Location))
                $ " melee=" $ int(Pawn.MeleeRange) $ " rad=" $ int(Pawn.CollisionRadius)
                $ " erad=" $ int(Enemy.CollisionRadius) $ " mass=" $ int(Pawn.Mass), 'MonsterArmyV1');
        }
        AttackStartHealth = 0;
        if (Pawn(Target) != None)
            AttackStartHealth = Pawn(Target).Health;
        FallbackTicks = 0;
        SetTimer(0.4, true);
    }

    function EndState()
    {
        SetTimer(0, false);
    }

    function Timer()
    {
        // stock firing behavior first - this triggers the pawn's own
        // attack (RangedAttack anims, projectiles, melee strikes)
        TimedFireWeaponAtEnemy();

        // direct-damage fallback for no-op RangedAttack packs (Dinotopia,
        // KF, ...) - deals damage when the pawn's own attack is doing nothing
        MaybeFallbackDamage();

        if (Enemy == None || Pawn == None || Enemy.Health <= 0)
            return;
        // Melee monster out of range - re-enter the action chooser so it
        // charges back into striking range.
        if (VSize(Enemy.Location - Pawn.Location)
            > Pawn.MeleeRange + Pawn.CollisionRadius + Enemy.CollisionRadius + 250)
        {
            if (Monster(Pawn) != None && Monster(Pawn).PreferMelee())
            {
                SetCombatTimer();
                StopFiring();
                WhatToDoNext(34);
            }
        }
    }

Begin:
    if (Enemy == None || Pawn == None)
    {
        Sleep(0.5);
        WhatToDoNext(43);
        Goto('Begin');
    }
    bHasFired = false;
    Focus = Target;
    Sleep(0.0);
    if (Enemy != None)
        CheckIfShouldCrouch(Pawn.Location, Enemy.Location, 1);
    if (NeedToTurn(Target.Location))
    {
        Focus = Target;
        FinishRotation();
    }
    bHasFired = true;
    if (Target == Enemy)
        TimedFireWeaponAtEnemy();
    else
        FireWeaponAt(Target);
    MaybeFallbackDamage();
    Sleep(0.1);
    // NOTE: melee monsters do NOT bail here anymore - the fallback above
    // needs the state to persist so its timer keeps dealing damage. Only
    // bail when the target changed or the pawn is a boss.
    if ((Target == None) || (Target != Enemy) || Monster(Pawn).bBoss)
        WhatToDoNext(35);
    if (Enemy != None)
        CheckIfShouldCrouch(Pawn.Location, Enemy.Location, 1);
    Focus = Target;
    Sleep(FMax(Monster(Pawn).RangedAttackTime(), 0.2 + (0.5 + 0.5 * FRand()) * 0.4 * (7 - Skill)));
    WhatToDoNext(36);
}

//------------------------------------------------------------------------------
// Direct-damage fallback - GLOBAL (outside the state!) on purpose.
// Declaring this inside state RangedAttack caused the server to CRASH with
// "Failed to find function MaybeFallbackDamage" when the state's Timer fired
// (state-local functions can fail to resolve from timer events). Global
// functions always resolve.
//------------------------------------------------------------------------------

// If the target's health isn't dropping and we're in striking range, deal
// direct damage. Called every attack cycle so packs whose own
// RangedAttack() is a no-op (Dinotopia, KF) still fight.
//
// NOTE: the outcome is VERIFIED, not the return value - some packs
// (Dinotopia) return true from MeleeDamageTarget WITHOUT dealing damage
// to same-species targets. If the health didn't actually drop, force
// the damage directly.
function MaybeFallbackDamage()
{
    local int Dmg;
    local int StartHP;
    local int NewHP;
    local float Reach;
    local Pawn Victim;
    local Pawn Attacker;

    Victim = Enemy;
    Attacker = Pawn;
    if (Victim == None || Attacker == None || Victim.Health <= 0)
        return;
    if (Victim.Health < AttackStartHealth - 1)
    {
        AttackStartHealth = Victim.Health;   // the pawn's own attack works
        return;
    }
    Reach = Attacker.MeleeRange + Attacker.CollisionRadius + Victim.CollisionRadius + 250;
    if (class'MonsterArmyGame'.default.bLogDamage)
        log("MA-FB: " $ Attacker $ " startHP=" $ AttackStartHealth $ " enemyHP=" $ Victim.Health
            $ " dist=" $ int(VSize(Victim.Location - Attacker.Location)) $ " reach=" $ int(Reach), 'MonsterArmyV1');
    if (VSize(Victim.Location - Attacker.Location) <= Reach)
    {
        Dmg = Max(15, int(25 * Attacker.Mass / 120.0));   // scale a bit with size
        Dmg = Min(Dmg, 120);   // cap: huge packs (dinosaurs) have enormous mass
        StartHP = Victim.Health;
        // Ask the pawn's own melee first (it plays the attack anim).
        Monster(Attacker).MeleeDamageTarget(Dmg, Normal(Victim.Location - Attacker.Location) * 25000);
        // Outcome check: did the health actually drop? If not, the
        // pack refused the damage - bypass it.
        if (class'MonsterArmyGame'.default.bLogDamage)
            log("MA-FB: " $ Attacker $ " after melee hp=" $ Victim.Health $ " (start " $ StartHP $ ")", 'MonsterArmyV1');
        if (Victim.Health >= StartHP)
        {
            // Some packs (Dinotopia) override TakeDamage and swallow
            // monster-vs-monster damage entirely - the health doesn't
            // move and no death fires. Bypass the override: apply the
            // health directly and drive the death flow ourselves.
            // NOTE: never touch Victim after Died() - the round cleanup
            // destroys the pawn and the reference becomes None.
            NewHP = Max(0, Victim.Health - Dmg);
            Victim.Health = NewHP;
            if (NewHP <= 0 && Attacker.Controller != None)
                Victim.Died(Attacker.Controller, class'SkaarjPack.MeleeDamage', Victim.Location);
            if (class'MonsterArmyGame'.default.bLogDamage)
                log("MA-FB: " $ Attacker $ " bypass dmg=" $ Dmg $ " hp now=" $ NewHP, 'MonsterArmyV1');
            AttackStartHealth = NewHP;
        }
    }
}

//------------------------------------------------------------------------------
// Stuck recovery - drop the monster next to its enemy with clear sight.
//------------------------------------------------------------------------------

function TeleportNextToEnemy()
{
    local vector Spot, HitLoc, HitNorm;
    local Actor Hit;
    local int i;
    local float A;

    if (Enemy == None || Pawn == None)
        return;

    for (i = 0; i < 16; i++)
    {
        A = i * 0.392699;   // 22.5 degree steps
        Spot = Enemy.Location;
        Spot.X += Cos(A) * (100 + FRand() * 200);
        Spot.Y += Sin(A) * (100 + FRand() * 200);
        Spot.Z += 40;
        Hit = Trace(HitLoc, HitNorm, Spot, Enemy.Location, false, Pawn.GetCollisionExtent());
        if (Hit == None)
        {
            Pawn.SetLocation(Spot);
            Pawn.SetPhysics(PHYS_Falling);
            Pawn.Velocity = vect(0,0,0);
            Pawn.SetRotation(rotator(Enemy.Location - Spot));
            SetRotation(rotator(Enemy.Location - Spot));
            return;
        }
    }

    // last resort - right beside the enemy
    Spot = Enemy.Location + vect(0, 1, 0) * (Pawn.CollisionRadius + Enemy.CollisionRadius + 40);
    Pawn.SetLocation(Spot);
    Pawn.SetPhysics(PHYS_Falling);
    Pawn.Velocity = vect(0,0,0);
}

defaultproperties
{
}
