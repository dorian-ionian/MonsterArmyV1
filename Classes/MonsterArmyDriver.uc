//=============================================================================
// MonsterArmyDriver
// A dedicated 1s timer actor that drives the war.
//
// Why this exists: GameInfo actors rely on their state machine Timer() to
// tick. If anything interferes with that (custom mods, state overrides),
// the war would stall. This actor ticks independently of the game's state
// machine so the battles ALWAYS run.
//
// It also force-starts the match if the stock PendingMatch state never does
// (e.g. no human players on a dedicated server).
//
// The war's TIME LIMIT is intentionally NOT handled here - it uses the
// stock RemainingTime clock (the same one every stock gametype uses),
// which the stock MatchInProgress.Timer decrements and which fires EndGame
// at zero.
//=============================================================================
class MonsterArmyDriver extends Info;

var MonsterArmyGame Game;
var int StartupClock;
var bool bForcedStart;

simulated function PostBeginPlay()
{
    Super.PostBeginPlay();
    if (Role == ROLE_Authority)
        SetTimer(1.0, true);
}

function Timer()
{
    if (Game == None)
    {
        Game = MonsterArmyGame(Level.Game);
        if (Game == None)
            return;
    }

    // --- force-start logic ---
    if (!bForcedStart)
    {
        if (Game.ShowHasStarted())
        {
            // the stock state machine already started the match on its own
            bForcedStart = true;
        }
        else
        {
            StartupClock++;
            if (StartupClock >= 8)
            {
                bForcedStart = true;
                log("MonsterArmyDriver: forcing match start (startup wait elapsed)", 'MonsterArmyV1');
                Game.StartMatch();
            }
        }
    }

    // --- Drive the war (once per second) ---
    Game.RoundTick();
}

defaultproperties
{
}
