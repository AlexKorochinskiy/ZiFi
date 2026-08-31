@echo off
cd /d "%~dp0"
spgbld.exe -b spgbld.ini zifi.spg
rem spgbld.exe -b spgbld_rs.ini zifi_rs.spg


mkdir ZIFI
del /s /q ZIFI\*.*
rem xcopy /Y zifi_rs.spg ZIFI\
C:\Windows\System32\xcopy.exe /Y zifi.spg ZIFI\
C:\Windows\System32\xcopy.exe /Y zifi.ini ZIFI\

rem SET IName="H:\speccy\_Emul\UnrealEvo_zifi\wc.img"

rem robimg.exe -p=%IName% -a=1 -f=1 -o=2048 -s=262144
rem robimg.exe -p=%IName% -a=1 -f=1 -s=131072

rem robimg.exe -p=%IName% -M="Test\InOne\InTwo\InThre1"
rem robimg.exe -p=%IName% -C="ZIFI",\ZIFI

rem del /s /q ZIFI\*.*
rem rmdir /s /q "ZIFI"
pause