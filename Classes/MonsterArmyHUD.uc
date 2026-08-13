//=============================================================================
// MonsterArmyHUD
// Broadcast-style overlay: the matchup banner, alive counts per army, the
// round counter and the phase countdown. Everything reads from
// MonsterArmyGRI so clients need no extra RPC plumbing.
//=============================================================================
class MonsterArmyHUD extends HudCDeathMatch;

simulated event PostRender(Canvas C)
{
    Super.PostRender(C);
    if (PlayerOwner == None || PlayerOwner.PlayerReplicationInfo == None)
        return;

    // The scoreboard (Tab) is a full-screen replacement - don't draw the
    // overlay on top of it.
    if (bShowScoreBoard)
        return;

    DrawArmyOverlay(C);
}

simulated function DrawArmyOverlay(Canvas C)
{
    local MonsterArmyGRI G;
    local float XL, YL, X;
    local color OldColor;
    local string S;

    G = MonsterArmyGRI(PlayerOwner.GameReplicationInfo);
    if (G == None)
        return;
    OldColor = C.DrawColor;
    X = C.ClipX * 0.5;

    // --- matchup banner ---
    C.Font = GetFontSizeIndex(C, 2);
    S = Caps(G.ArmyAName) $ " VS " $ Caps(G.ArmyBName);
    C.TextSize(S, XL, YL);
    C.SetPos(X - XL * 0.5, 18);
    C.DrawColor.R = 255;
    C.DrawColor.G = 255;
    C.DrawColor.B = 255;
    C.DrawColor.A = 220;
    C.DrawText(S);

    // --- matchup number + round ---
    C.Font = GetFontSizeIndex(C, 0);
    S = "MATCHUP " $ G.MatchupNumber $ "   -   ROUND " $ Min(G.RoundNumber, G.RoundsTotal) $ " OF " $ G.RoundsTotal;
    C.TextSize(S, XL, YL);
    C.SetPos(X - XL * 0.5, 18 + YL + 2);
    C.DrawColor.A = 180;
    C.DrawText(S);

    // --- alive counts ---
    C.Font = GetFontSizeIndex(C, 1);
    S = "ARMY A: " $ G.AliveA $ " ALIVE";
    C.TextSize(S, XL, YL);
    C.SetPos(X - XL - 30, 18 + 2 * YL + 4);
    C.DrawColor.R = 255;
    C.DrawColor.G = 60;
    C.DrawColor.B = 60;
    C.DrawColor.A = 255;
    C.DrawText(S);

    S = "ARMY B: " $ G.AliveB $ " ALIVE";
    C.TextSize(S, XL, YL);
    C.SetPos(X + 30, 18 + 2 * YL + 4);
    C.DrawColor.R = 80;
    C.DrawColor.G = 140;
    C.DrawColor.B = 255;
    C.DrawColor.A = 255;
    C.DrawText(S);

    // --- phase countdown ---
    C.Font = GetFontSizeIndex(C, 0);
    C.DrawColor.R = 255;
    C.DrawColor.G = 255;
    C.DrawColor.B = 255;
    C.DrawColor.A = 200;
    switch (G.Phase)
    {
        case 1:   // PHASE_FIGHT
            S = "TIME LEFT: " $ FormatTime(G.PhaseTimeLeft);
            break;
        case 2:   // PHASE_RESULT
            S = "NEXT ROUND IN " $ G.PhaseTimeLeft;
            break;
        case 3:   // PHASE_INTERMISSION
            S = "NEW ARMIES IN " $ G.PhaseTimeLeft;
            break;
        default:
            S = "";
            break;
    }
    if (S != "")
    {
        C.TextSize(S, XL, YL);
        C.SetPos(X - XL * 0.5, 18 + 3 * YL + 6);
        C.DrawText(S);
    }

    C.DrawColor = OldColor;
}

simulated function string FormatTime(int T)
{
    local int M, S;
    M = T / 60;
    S = T % 60;
    if (S < 10)
        return string(M) $ ":0" $ string(S);
    return string(M) $ ":" $ string(S);
}

defaultproperties
{
}
