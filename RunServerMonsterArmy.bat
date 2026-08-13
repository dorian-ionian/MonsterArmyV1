@echo off
:10
ucc server ONS-Torlan?game=MonsterArmyV1.MonsterArmyGame -ini=UT2004MonsterArmy.ini -log=MonsterArmy_server.log
copy MonsterArmy_server.log MonsterArmy_servercrash.log
goto 10
