//=============================================================================
// MonsterArmyGRI
// Replicated war state so every spectator's HUD can show the show.
//=============================================================================
class MonsterArmyGRI extends GameReplicationInfo;

// Phase constants - mirrored from MonsterArmyGame.
const PHASE_IDLE          = 0;
const PHASE_FIGHT         = 1;
const PHASE_RESULT        = 2;
const PHASE_INTERMISSION  = 3;

var string ArmyAName, ArmyBName;    // roster names of the current matchup
var int AliveA, AliveB;             // living monster counts
var byte Phase;                     // see the phase constants above
var int RoundNumber;                // current round (clamped to the total)
var int RoundsTotal;                // best-of-N rounds per matchup
var int MatchupNumber;              // how many matchups have been booked
var int RoundWinsA, RoundWinsB;     // current matchup score
var int PhaseTimeLeft;              // countdown for the HUD
var bool bShowEnded;                // the war clock fired - show is over

replication
{
    // Names must keep replicating on every matchup change, not just the
    // initial GRI send - otherwise the HUD shows stale armies.
    reliable if ((bNetInitial || bNetDirty) && Role == ROLE_Authority)
        ArmyAName, ArmyBName, RoundsTotal;

    reliable if (bNetDirty && Role == ROLE_Authority)
        Phase, RoundNumber, MatchupNumber, PhaseTimeLeft, RoundWinsA, RoundWinsB, AliveA, AliveB, bShowEnded;
}

defaultproperties
{
}
