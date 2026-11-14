@echo off
setlocal enabledelayedexpansion

:: ========================== SETTINGS ==========================
set "SCRIPT_VERSION=1.2.1"
set "TEMPLATE_DIR=Coding\coding-templates\agents\opencode"
set "CONFIG_FILE=deploy-AGENTS.md-config.json"
:: =============================================================

set "ROOT_DIR=%CD%"
if "!ROOT_DIR:~-1!"=="\" set "ROOT_DIR=!ROOT_DIR:~0,-1!"

for %%I in ("%TEMPLATE_DIR%") do set "TEMPLATE_DIR_ABS=%%~fI"
set "TEMPLATE_AGENTS=%TEMPLATE_DIR_ABS%\AGENTS.md"
set "TEMPLATE_AI_STATE=%TEMPLATE_DIR_ABS%\ai_state.md"

if not exist "%TEMPLATE_AGENTS%" (
    echo Error: Template AGENTS.md not found at "%TEMPLATE_AGENTS%"
    pause & exit /b 1
)
if not exist "%TEMPLATE_AI_STATE%" (
    echo Error: Template ai_state.md not found at "%TEMPLATE_AI_STATE%"
    pause & exit /b 1
)

:: ---------- Read template version ----------
call :GetVersion "%TEMPLATE_AGENTS%"
set "TEMPLATE_VERSION=!FOUND_VERSION!"
if "!TEMPLATE_VERSION!"=="No version" (
    echo Error: The template AGENTS.md has no valid version number on its first line.
    pause & exit /b 1
)

:: ---------- Load JSON exclude list ----------
:: NOTE: quote-stripping is done in plain SET commands, never inside an
:: IF comparison, to avoid the cmd quote-parsing crash.
set /a EXCLUDE_COUNT=0
set "EXCLUDE_DISPLAY="
if exist "%CONFIG_FILE%" (
    for /f "usebackq delims=" %%A in ("%CONFIG_FILE%") do (
        set "LINE=%%A"
        set "HAS_COLON=0"
        if not "!LINE::=!"=="!LINE!" set "HAS_COLON=1"
        if "!HAS_COLON!"=="0" (
            set "ITEM=!LINE:"=!"
            set "ITEM=!ITEM:,=!"
            set "ITEM=!ITEM:[=!"
            set "ITEM=!ITEM:]=!"
            set "ITEM=!ITEM:{=!"
            set "ITEM=!ITEM:}=!"
            call :Trim "!ITEM!"
            if defined TRIMMED (
                set /a EXCLUDE_COUNT+=1
                set "EXCLUDE_!EXCLUDE_COUNT!=!TRIMMED!"
                if defined EXCLUDE_DISPLAY (
                    set "EXCLUDE_DISPLAY=!EXCLUDE_DISPLAY!, !TRIMMED!"
                ) else (
                    set "EXCLUDE_DISPLAY=!TRIMMED!"
                )
            )
        )
    )
)

:: ---------- Header ----------
echo Deploy Script v%SCRIPT_VERSION%
echo AGENTS.md version %TEMPLATE_VERSION%
echo currently deploying...
echo.
echo NOTE: This script must be run from the Root directory.
echo NOTE: Projects must have a README.md file present in order to be deployed to.
echo NOTE: Subfolders next to a README.md are skipped, including their contents.
echo NOTE: Excluded folders are skipped along with all of their subfolders.
if defined EXCLUDE_DISPLAY echo NOTE: Excluding folders: !EXCLUDE_DISPLAY!
echo.

:MODE_PROMPT
echo Select deployment mode:
echo 1. Automatically replace/add all projects
echo 2. Approve each project individually
echo.
set "MODE_CHOICE="
set /p "MODE_CHOICE=Enter your choice (1 or 2): "
if "%MODE_CHOICE%"=="1" (set "MODE=AUTO") else if "%MODE_CHOICE%"=="2" (set "MODE=MANUAL") else (
    echo Invalid choice. Please enter 1 or 2.
    goto MODE_PROMPT
)

echo.
echo Scanning projects...
echo.

set /a PROJECTS=0
set /a AGENTS_REPLACED=0
set /a AGENTS_ADDED=0
set /a STATE_ADDED=0
set /a PRUNED=0
set /a EXCLUDED=0

call :WalkTree "%ROOT_DIR%"

echo.
echo ---------------------------------------------
echo Projects found           : %PROJECTS%
echo AGENTS.md replaced       : %AGENTS_REPLACED%
echo AGENTS.md added          : %AGENTS_ADDED%
echo ai_state.md added        : %STATE_ADDED%
echo Project subtrees stopped : %PRUNED%
echo Excluded subtrees        : %EXCLUDED%
echo ---------------------------------------------
echo Deployment complete.
endlocal
pause
exit /b 0


:: =====================================================================
:: WalkTree  -  %1 = folder path (no trailing backslash)
::   - folder name in exclude list  -> skip folder + entire subtree
::   - folder has README.md         -> deploy, then STOP descending
::   - otherwise                    -> keep descending (category folder)
:: =====================================================================
:WalkTree
set "WT_DIR=%~1"
set "WT_NAME="
for %%X in ("%WT_DIR%") do set "WT_NAME=%%~nxX"

set "WT_SKIP=0"
if /i not "!WT_DIR!"=="!ROOT_DIR!" (
    if /i "!WT_DIR!"=="!TEMPLATE_DIR_ABS!" set "WT_SKIP=1"
    if !EXCLUDE_COUNT! gtr 0 (
        for /l %%i in (1,1,!EXCLUDE_COUNT!) do (
            if /i "!WT_NAME!"=="!EXCLUDE_%%i!" set "WT_SKIP=1"
        )
    )
)
if "!WT_SKIP!"=="1" (
    set /a EXCLUDED+=1
    exit /b 0
)

if exist "!WT_DIR!\README.md" (
    if /i not "!WT_DIR!"=="!ROOT_DIR!" (
        call :DeployProject "!WT_DIR!"
        set /a PRUNED+=1
        exit /b 0
    )
)

for /f "delims=" %%D in ('dir /b /a:d-l "%~1" 2^>nul') do call :WalkTree "%~1\%%D"
exit /b 0


:: =====================================================================
:: DeployProject  -  %1 = project folder
:: =====================================================================
:DeployProject
set "P_DIR=%~1"
set /a PROJECTS+=1

:: ---- AGENTS.md ----
if exist "!P_DIR!\AGENTS.md" (
    call :GetVersion "!P_DIR!\AGENTS.md"
    if "!FOUND_VERSION!" neq "%TEMPLATE_VERSION%" (
        if "!MODE!"=="AUTO" (
            copy /y "%TEMPLATE_AGENTS%" "!P_DIR!\AGENTS.md" >nul
            set /a AGENTS_REPLACED+=1
            echo Replaced AGENTS.md for project: !P_DIR!
        ) else (
            echo Project: !P_DIR!
            echo AGENTS.md Version: !FOUND_VERSION! --^> %TEMPLATE_VERSION%
            set "CONFIRM=Y"
            set /p "CONFIRM=Replace this file? (Y/N) [Y]: "
            if /i "!CONFIRM!"=="N" (
                echo Skipped AGENTS.md for project: !P_DIR!
            ) else (
                copy /y "%TEMPLATE_AGENTS%" "!P_DIR!\AGENTS.md" >nul
                set /a AGENTS_REPLACED+=1
                echo Replaced AGENTS.md for project: !P_DIR!
            )
            echo.
        )
    )
) else (
    if "!MODE!"=="AUTO" (
        copy /y "%TEMPLATE_AGENTS%" "!P_DIR!\AGENTS.md" >nul
        set /a AGENTS_ADDED+=1
        echo Added missing AGENTS.md for project: !P_DIR!
    ) else (
        echo Project: !P_DIR!
        echo Status: Missing AGENTS.md
        set "CONFIRM=Y"
        set /p "CONFIRM=Add AGENTS.md? (Y/N) [Y]: "
        if /i "!CONFIRM!"=="N" (
            echo Skipped AGENTS.md for project: !P_DIR!
        ) else (
            copy /y "%TEMPLATE_AGENTS%" "!P_DIR!\AGENTS.md" >nul
            set /a AGENTS_ADDED+=1
            echo Added missing AGENTS.md for project: !P_DIR!
        )
        echo.
    )
)

:: ---- ai_state.md ----
if not exist "!P_DIR!\ai_state.md" (
    if "!MODE!"=="AUTO" (
        copy /y "%TEMPLATE_AI_STATE%" "!P_DIR!\ai_state.md" >nul
        set /a STATE_ADDED+=1
        echo Added missing ai_state.md for project: !P_DIR!
    ) else (
        echo Project: !P_DIR!
        echo Status: Missing ai_state.md
        set "CONFIRM=Y"
        set /p "CONFIRM=Add ai_state.md? (Y/N) [Y]: "
        if /i "!CONFIRM!"=="N" (
            echo Skipped ai_state.md for project: !P_DIR!
        ) else (
            copy /y "%TEMPLATE_AI_STATE%" "!P_DIR!\ai_state.md" >nul
            set /a STATE_ADDED+=1
            echo Added missing ai_state.md for project: !P_DIR!
        )
        echo.
    )
)
exit /b 0


:: =====================================================================
:: GetVersion  -  %1 = file ; returns FOUND_VERSION
:: =====================================================================
:GetVersion
set "FOUND_VERSION="
set "FOUND_LINE="
set /p FOUND_LINE=<"%~1" 2>nul
if not defined FOUND_LINE (set "FOUND_VERSION=No version" & exit /b 0)
set "CLEAN_FOUND=!FOUND_LINE:version =!"
set "CLEAN_FOUND=!CLEAN_FOUND:Version =!"
set "CLEAN_FOUND=!CLEAN_FOUND:VERSION =!"
set "CLEAN_FOUND=!CLEAN_FOUND:# =!"
set "CLEAN_FOUND=!CLEAN_FOUND:**=!"
call :Trim "!CLEAN_FOUND!"
set "CLEAN_FOUND=!TRIMMED!"
if /i "!CLEAN_FOUND:~0,1!"=="v" set "CLEAN_FOUND=!CLEAN_FOUND:~1!"
echo(!CLEAN_FOUND!| findstr /r "^[0-9][0-9]*\.[0-9]" >nul
if errorlevel 1 (set "FOUND_VERSION=No version" & exit /b 0)
for /f "tokens=1" %%V in ("!CLEAN_FOUND!") do set "FOUND_VERSION=%%V"
exit /b 0


:: =====================================================================
:: Trim  -  %1 = text ; returns TRIMMED
:: =====================================================================
:Trim
set "TRIMMED=%~1"
:TrimLoop
if defined TRIMMED if "!TRIMMED:~0,1!"==" " (set "TRIMMED=!TRIMMED:~1!" & goto TrimLoop)
if defined TRIMMED if "!TRIMMED:~-1!"==" " (set "TRIMMED=!TRIMMED:~0,-1!" & goto TrimLoop)
exit /b 0