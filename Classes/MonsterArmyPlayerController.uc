//=============================================================================
// MonsterArmyPlayerController
// Locked spectator for the Monster Army arena. The game forces every
// joining player into the Spectating state; the stock spectator camera
// (LMB/RMB cycling) handles all the view work.
//
// Kept as a distinct class so the gametype can reference it and future
// client features (RPCs, menu hooks) have a home.
//=============================================================================
class MonsterArmyPlayerController extends XPlayer;

defaultproperties
{
}
