#cs
    PTBurnSDK.au3
    -------------
    Reusable AutoIt wrapper for the Primera PTBurn SDK (file-based interface),
    based on the official PTDevSuite SampleClient (v3.3.4) and extended to
    support hardware introduced through SDK v3.4.4 (DP 4200 XRP, SE-3,
    combined ink cartridge type 6, etc.).

    All status data is parsed from:
        \\<server>\PTBurnJobs\Status\SystemStatus.txt   (robot list & per-robot)
        \\<server>\PTBurnJobs\Status\<robot status file> (drives & jobs)

    Commands are issued by writing .ptm message files into:
        \\<server>\PTBurnJobs\

    Public API
    ----------
        _PTBurn_Init([$sServer = @ComputerName [, $bUnicode = False]])
        _PTBurn_Shutdown()
        _PTBurn_ShareReachable()              -> True if \\server\PTBurnJobs is accessible
        _PTBurn_SetCachePath($sPath)          -> override default PTBurnJobCache.ini location

        _PTBurn_GetRobots()                   -> 2D array, one row per robot
        _PTBurn_GetRobotImage($aRobot)        -> path to .png for the robot type
        _PTBurn_GetBins($aRobot)              -> 1D array [Left, Right, HasRight]
        _PTBurn_GetCartridges($aRobot)        -> 2D array, one row per cart
        _PTBurn_GetDrives($aRobot)            -> 2D array, one row per drive
        _PTBurn_GetJobs($aRobot)              -> 2D array, one row per job
        _PTBurn_GetSystemInfo($aRobot)        -> 1D array [FW, Serial, ManfDate,
                                                            Status, Error, ErrNum]
        _PTBurn_SendMessage($aRobot, $sMsg)   -> writes Msg_<guid>.ptm
        _PTBurn_AbortJob($aRobot, $sJobName)  -> writes <job>.ptm Message=ABORT
        _PTBurn_SendIgnoreInkLow($aRobot)     -> writes Msg_<guid>.ptm IGNORE_INKLOW
        _PTBurn_CartColor($iPercent)          -> RGB
        _PTBurn_JobRowColor($iState, $bCompleted) -> RGB

    Record layouts (column index constants)
    ---------------------------------------
    Robot row:  $PT_R_NAME, $PT_R_STATUSFILE, $PT_R_TYPE, $PT_R_TYPENAME
    Bins:       $PT_B_LEFT, $PT_B_RIGHT, $PT_B_HASRIGHT
                  ($PT_B_HASRIGHT = False on single-bin robots; caller should
                   hide the Right bin display in that case)
    Cart row:   $PT_C_NAME, $PT_C_FILL
    Drive row:  $PT_D_DESC, $PT_D_LOCATION, $PT_D_STATE, $PT_D_STATETEXT,
                $PT_D_PERCENT, $PT_D_JOB, $PT_D_DISC
    Job row:    $PT_J_NAME, $PT_J_STATE, $PT_J_STATETEXT, $PT_J_GOOD,
                $PT_J_BAD, $PT_J_REMAINING, $PT_J_STATUS, $PT_J_COMPLETED
    SysInfo:    $PT_S_FW, $PT_S_SERIAL, $PT_S_MANFDATE, $PT_S_STATUS,
                $PT_S_ERROR, $PT_S_ERRNUM

    Unicode note
    ------------
    Pass $bUnicode = True to _PTBurn_Init when running the Unicode build of
    PTBurnService (Version_3_4_4\UNICODE\).  PTBurnHistory.txt states that
    .PTM files MUST be Unicode-encoded in that configuration, and the service
    also writes job files (.JRQ/.QRJ/.INP/.DON/.ERR) as UTF-16 LE with a BOM.

    Two distinct read paths exist, and they require different handling:

    1. IniRead() -- used for all .txt status files (SystemStatus.txt,
       RobotName.txt).  AutoIt's IniRead wraps GetPrivateProfileStringW, which
       detects the UTF-16 LE BOM automatically.  No special handling needed;
       IniRead works correctly with both ANSI and Unicode builds as-is.

    2. FileOpen/FileReadLine -- used only in _PTBurn_AddJobFromFile() to parse
       job files (.JRQ/.QRJ/.INP/.DON/.ERR).  These files are plain "Key = Value"
       text, not INI format, so IniRead cannot be used.  When $g_bPTBurn_Unicode
       is True, FileOpen is called with mode 32 ($FO_UNICODE / UTF-16 LE); when
       False it uses mode 0 (ANSI).  This matches the SDK SampleClient behaviour.
#ce

#include-once
#include <Array.au3>
#include <File.au3>
#include <WinAPI.au3>
#include <SendMessage.au3>

; ============================================================================
; CONSTANTS
; ============================================================================

; Cartridge thresholds (no SDK-defined percentage; LOW is signalled only via
; SystemError COLOR_LOW/BLACK_LOW). Sensible defaults; override if needed.
Global Const $PTBURN_CART_OK_PCT   = 30   ; >= = green
Global Const $PTBURN_CART_WARN_PCT = 10   ; >= = yellow, < = red

; Maximum drives supported per robot.  The SDK itself has no hard cap (StatusFile.cs
; RefreshDrives uses an unbounded loop), but hardware tops out at 4 on current models.
; Raise this if Primera ever ships a unit with more drives; update $g_aDriveCtrls in
; PTBurnStatusGUI.au3 to match.
Global Const $PTBURN_MAX_DRIVES = 8

; Win32 constants for Pic-control image swapping
Global Const $PT_STM_SETIMAGE = 0x0172
Global Const $PT_IMAGE_BITMAP = 0

; Row colours (RGB - GUICtrlSetBkColor takes RGB)
Global Const $PTBURN_COL_OK    = 0xCCFFCC ; light green  - Done
Global Const $PTBURN_COL_WARN  = 0xFFFFCC ; light yellow - Processing
Global Const $PTBURN_COL_INFO  = 0xCCE5FF ; light blue   - Queued
Global Const $PTBURN_COL_BAD   = 0xFFCCCC ; light red    - Error
Global Const $PTBURN_COL_WHITE = 0xFFFFFF ; white        - Submitted

; RobotType enum — PDF §3.1.3.2 (doc rev 3.2.5, March 2017)
Global Const $PTBURN_ROBOT_DP             = 0   ; Disc Publisher
Global Const $PTBURN_ROBOT_DPII           = 1   ; Disc Publisher II
Global Const $PTBURN_ROBOT_DPPRO          = 2   ; Disc Publisher PRO
; 3 = not defined in SDK docs
Global Const $PTBURN_ROBOT_DPXR           = 4   ; Disc Publisher XR  (was wrongly named RACKMOUNT_DPII)
Global Const $PTBURN_ROBOT_RACKMOUNT_DPII = 4   ; alias kept for backward compatibility
Global Const $PTBURN_ROBOT_DPXRP          = 5   ; Disc Publisher XRP
Global Const $PTBURN_ROBOT_DPSE           = 6   ; Disc Publisher SE
Global Const $PTBURN_ROBOT_DPPRO_XI       = 7   ; Disc Publisher Pro Xi
Global Const $PTBURN_ROBOT_DP_4100        = 8   ; Disc Publisher 4100
Global Const $PTBURN_ROBOT_DP_4100_XRP    = 9   ; Disc Publisher 4100 XRP
Global Const $PTBURN_ROBOT_DP_4051        = 10  ; Disc Publisher 4051
Global Const $PTBURN_ROBOT_DPSE3          = 11  ; Disc Publisher SE-3
Global Const $PTBURN_ROBOT_DP_4200        = 12  ; Disc Publisher 4200
Global Const $PTBURN_ROBOT_DP_4200_XRP    = 13  ; Disc Publisher 4200 XRP
Global Const $PTBURN_ROBOT_DP_4052        = 14  ; Disc Publisher 4052

; JobState enum — SDK C# (StatusFile.cs) defines 0–3; state 4 (MOVED) was added in
; PTBurn 3.3.0 (PTBurnHistory.txt: CurrentStatusState=18, "moved to another robot");
; state 5 (QUEUED) is internal to this wrapper, derived from the .QRJ file extension.
Global Const $PTBURN_JOB_NOT_STARTED = 0   ; .JRQ Submitted (white)
Global Const $PTBURN_JOB_RUNNING     = 1   ; .INP Processing (yellow)
Global Const $PTBURN_JOB_COMPLETED   = 2   ; .DON Complete (green)
Global Const $PTBURN_JOB_FAILED      = 3   ; .ERR Error (red)
Global Const $PTBURN_JOB_MOVED       = 4   ; PTBurn 3.3.0+: job moved to another robot
Global Const $PTBURN_JOB_QUEUED      = 5   ; .QRJ Queued (blue) — internal, not a SDK JobState

; DriveState enum — PDF §3.2.5.14 / StatusFile.cs DriveState enum.
; Note: the SDK C# source misspells state 5 as "VEFIFY_FAILED" (missing 'R').
; Our constant uses the correct spelling.
Global Const $PTBURN_DRV_IDLE            = 0
Global Const $PTBURN_DRV_RECORDING       = 1
Global Const $PTBURN_DRV_READING         = 2
Global Const $PTBURN_DRV_VERIFYING       = 3
Global Const $PTBURN_DRV_DISC_LOADED     = 4
Global Const $PTBURN_DRV_VERIFY_FAILED   = 5
Global Const $PTBURN_DRV_VERIFY_COMPLETE = 6
Global Const $PTBURN_DRV_RECORD_FAILED   = 7
Global Const $PTBURN_DRV_RECORD_COMPLETE = 8

; --- Record layout column indices --------------------------------------------
; Robot row
Global Const $PT_R_NAME       = 0
Global Const $PT_R_STATUSFILE = 1
Global Const $PT_R_TYPE       = 2
Global Const $PT_R_TYPENAME   = 3
Global Const $PT_R_FIELDS     = 4

; Bins
Global Const $PT_B_LEFT     = 0
Global Const $PT_B_RIGHT    = 1
Global Const $PT_B_HASRIGHT = 2   ; True = robot has a right bin; False = single-bin robot

; Cartridge row
Global Const $PT_C_NAME   = 0
Global Const $PT_C_FILL   = 1
Global Const $PT_C_FIELDS = 2

; Drive row
Global Const $PT_D_DESC      = 0
Global Const $PT_D_LOCATION  = 1
Global Const $PT_D_STATE     = 2
Global Const $PT_D_STATETEXT = 3
Global Const $PT_D_PERCENT   = 4
Global Const $PT_D_JOB       = 5
Global Const $PT_D_DISC      = 6
Global Const $PT_D_FIELDS    = 7

; Job row
Global Const $PT_J_NAME      = 0
Global Const $PT_J_STATE     = 1
Global Const $PT_J_STATETEXT = 2
Global Const $PT_J_GOOD      = 3
Global Const $PT_J_BAD       = 4
Global Const $PT_J_REMAINING = 5
Global Const $PT_J_STATUS    = 6
Global Const $PT_J_COMPLETED = 7
Global Const $PT_J_STEM      = 8   ; filename stem — used by abort command
Global Const $PT_J_FIELDS    = 9

; SystemInfo
Global Const $PT_S_FW       = 0
Global Const $PT_S_SERIAL   = 1
Global Const $PT_S_MANFDATE = 2
Global Const $PT_S_STATUS   = 3
Global Const $PT_S_ERROR    = 4   ; SysErrorString (human-readable)
Global Const $PT_S_ERRNUM   = 5   ; SysErrorNumber (numeric; 0 = no error)

; ============================================================================
; MODULE STATE
; ============================================================================
Global $g_sPTBurn_Server     = ""
Global $g_sPTBurn_JobsRoot   = ""
Global $g_sPTBurn_StatusDir  = ""
Global $g_sPTBurn_SystemFile = ""
Global $g_sPTBurn_ImagesDir  = @ScriptDir & "\Images"
; Set to True if PTBurnService is the Unicode build (Version_3_4_4\UNICODE\).
; PTBurnHistory.txt: "Some files MUST have Unicode encoding including .JRQ, .PTM, .INI"
; when running the Unicode service.  Controls both write encoding (_PTBurn_OpenPtm)
; and read encoding (_PTBurn_AddJobFromFile).  ANSI build uses False (default).
Global $g_bPTBurn_Unicode    = False

; Client-side job completion cache — stores GoodDiscs/BadDiscs/Status for the last
; $PTBURN_CACHE_MAX completed jobs so results survive PTBurnService's [CompletedJobs]
; rotation.  Written to @ScriptDir by default; override with _PTBurn_SetCachePath().
Global Const $PTBURN_CACHE_MAX = 99
Global $g_sPTBurn_CacheFile  = @ScriptDir & "\PTBurnJobCache.ini"

; ============================================================================
; INIT / SHUTDOWN
; ============================================================================
; $sServer   - hostname sharing PTBurnJobs (default = local machine)
; $bUnicode  - set True when running the Unicode build of PTBurnService so that
;              .ptm command files are written with UTF-16 LE encoding, matching
;              the SDK SampleClient UnicodeEncoding setting.
Func _PTBurn_Init($sServer = Default, $bUnicode = False)
    If $sServer = Default Or $sServer = "" Then $sServer = @ComputerName
    $g_sPTBurn_Server     = $sServer
    $g_sPTBurn_JobsRoot   = "\\" & $sServer & "\PTBurnJobs"
    $g_sPTBurn_StatusDir  = $g_sPTBurn_JobsRoot & "\Status"
    $g_sPTBurn_SystemFile = $g_sPTBurn_StatusDir & "\SystemStatus.txt"
    $g_bPTBurn_Unicode    = $bUnicode
EndFunc

Func _PTBurn_Shutdown()
    ; Nothing to tear down — GDI+ is managed by the caller (PTBurnStatusGUI.au3).
    ; This function is kept so callers have a clean paired _Init/_Shutdown pattern
    ; and in case future SDK state needs cleanup.
EndFunc

Func _PTBurn_SystemFileExists()
    Return FileExists($g_sPTBurn_SystemFile)
EndFunc

; Returns True if the PTBurnJobs share directory itself is reachable.
; This is a stronger check than SystemFileExists() — it detects a missing share
; even before SystemStatus.txt has been created (e.g. first-time install or
; network outage that takes down the share but not the Windows service).
Func _PTBurn_ShareReachable()
    If $g_sPTBurn_JobsRoot = "" Then Return False
    Return FileExists($g_sPTBurn_JobsRoot)
EndFunc

; Override the default cache file path.  Call before _PTBurn_Init if needed.
; Default: @ScriptDir & "\PTBurnJobCache.ini"
Func _PTBurn_SetCachePath($sPath)
    $g_sPTBurn_CacheFile = $sPath
EndFunc

; ============================================================================
; JOB COMPLETION CACHE
; ============================================================================
; PTBurnService only retains the last ~4 completed jobs in RobotName.txt.
; We maintain our own PTBurnJobCache.ini alongside the script, keeping the last
; $PTBURN_CACHE_MAX (99) completed jobs so Good/Bad counts and final status
; survive the server-side rotation.
;
; Cache file layout (standard Windows INI):
;
;   [_Index]
;   Count=12
;   Order=stem0|stem1|stem2|...   (oldest first; pipe-delimited)
;
;   [StemName]
;   JobTitle=OE 4.10 - Disc 1 of 1 - Windows 11 COTS DVD DL
;   GoodDiscs=1
;   BadDiscs=0
;   Status=The job is complete...
;   TimeCompleted=05/13/2026 13:26:55
;
; All section names (stems) are stored as-is (mixed case) but looked up
; case-insensitively via IniRead's default behaviour on Windows.
; ============================================================================

; Internal — apply cached data for $sStem into row $iRow of 2D array $aOut.
; Returns True if the cache had an entry for $sStem, False if not found.
; Takes the full 2D array and row index because AutoIt does not support passing
; a single row of a 2D array as a ByRef parameter.
Func _PTBurn_CacheRead($sStem, ByRef $aOut, $iRow)
    If $g_sPTBurn_CacheFile = "" Or Not FileExists($g_sPTBurn_CacheFile) Then Return False
    Local $sGood = IniRead($g_sPTBurn_CacheFile, $sStem, "GoodDiscs", "")
    If $sGood = "" Then Return False   ; section absent
    $aOut[$iRow][$PT_J_GOOD]   = Int($sGood)
    $aOut[$iRow][$PT_J_BAD]    = Int(IniRead($g_sPTBurn_CacheFile, $sStem, "BadDiscs", "0"))
    $aOut[$iRow][$PT_J_STATUS] = IniRead($g_sPTBurn_CacheFile, $sStem, "Status",   "")
    ; Restore JobTitle into the display name only if the row currently shows the stem
    Local $sCachedTitle = IniRead($g_sPTBurn_CacheFile, $sStem, "JobTitle", "")
    If $sCachedTitle <> "" And $aOut[$iRow][$PT_J_NAME] = $sStem Then
        $aOut[$iRow][$PT_J_NAME] = $sCachedTitle
    EndIf
    Return True
EndFunc

; Internal — write/update one completed job's data into the cache.
; Evicts the oldest entry if the cache already holds $PTBURN_CACHE_MAX jobs.
; Only writes entries where GoodDiscs+BadDiscs > 0 or Status is non-generic,
; so we don't cache placeholder rows that have no real data yet.
Func _PTBurn_CacheWrite($sStem, $sJobTitle, $iGood, $iBad, $sStatus, $sTimeCompleted)
    If $g_sPTBurn_CacheFile = "" Then Return
    If $sStem = "" Then Return

    ; Don't cache if we have no meaningful completion data
    If $iGood = 0 And $iBad = 0 And ($sStatus = "" Or $sStatus = "Complete") Then Return

    ; Read the current order list
    Local $sOrder = IniRead($g_sPTBurn_CacheFile, "_Index", "Order", "")
    Local $aOrder
    If $sOrder = "" Then
        Local $aEmpty[0]
        $aOrder = $aEmpty
    Else
        $aOrder = StringSplit($sOrder, "|", 2)   ; mode 2 = no count element
    EndIf

    ; Check if this stem is already in the index — if so remove it so we can
    ; re-insert at the end (most-recent position) without duplication.
    Local $iExisting = -1
    For $k = 0 To UBound($aOrder) - 1
        If $aOrder[$k] = $sStem Then
            $iExisting = $k
            ExitLoop
        EndIf
    Next

    If $iExisting >= 0 Then
        ; Remove from its current position
        Local $aNew[UBound($aOrder) - 1]
        Local $iDst = 0
        For $k = 0 To UBound($aOrder) - 1
            If $k = $iExisting Then ContinueLoop
            $aNew[$iDst] = $aOrder[$k]
            $iDst += 1
        Next
        $aOrder = $aNew
    EndIf

    ; Evict oldest entries if at capacity
    While UBound($aOrder) >= $PTBURN_CACHE_MAX
        Local $sEvict = $aOrder[0]
        IniDelete($g_sPTBurn_CacheFile, $sEvict)
        ; Shift array left by one
        Local $aShifted[UBound($aOrder) - 1]
        For $k = 1 To UBound($aOrder) - 1
            $aShifted[$k - 1] = $aOrder[$k]
        Next
        $aOrder = $aShifted
    WEnd

    ; Append this stem at the end (newest)
    ReDim $aOrder[UBound($aOrder) + 1]
    $aOrder[UBound($aOrder) - 1] = $sStem

    ; Write the job section
    IniWrite($g_sPTBurn_CacheFile, $sStem, "JobTitle",       $sJobTitle)
    IniWrite($g_sPTBurn_CacheFile, $sStem, "GoodDiscs",      $iGood)
    IniWrite($g_sPTBurn_CacheFile, $sStem, "BadDiscs",       $iBad)
    IniWrite($g_sPTBurn_CacheFile, $sStem, "Status",         $sStatus)
    IniWrite($g_sPTBurn_CacheFile, $sStem, "TimeCompleted",  $sTimeCompleted)

    ; Update the index
    IniWrite($g_sPTBurn_CacheFile, "_Index", "Count", UBound($aOrder))
    IniWrite($g_sPTBurn_CacheFile, "_Index", "Order", _ArrayToString($aOrder, "|"))
EndFunc

; ============================================================================
; ROBOTS
; ============================================================================
Func _PTBurn_GetRobots()
    Local $aOut[0][$PT_R_FIELDS]
    If Not FileExists($g_sPTBurn_SystemFile) Then Return $aOut

    ; SDK SystemStatus.Refresh() uses an unbounded while loop breaking on the
    ; first absent Robot key — no hard cap on robot count.
    Local $iRow = 0, $i = 0
    While 1
        Local $sName = IniRead($g_sPTBurn_SystemFile, "RobotList", "Robot" & $i, "")
        If $sName = "" Then ExitLoop

        Local $sStatusFile = IniRead($g_sPTBurn_SystemFile, $sName, "StatusFile", "")
        Local $iType       = Int(IniRead($g_sPTBurn_SystemFile, $sName, "RobotType", "3"))

        ReDim $aOut[$iRow + 1][$PT_R_FIELDS]
        $aOut[$iRow][$PT_R_NAME]       = $sName
        $aOut[$iRow][$PT_R_STATUSFILE] = $g_sPTBurn_StatusDir & "\" & $sStatusFile
        $aOut[$iRow][$PT_R_TYPE]       = $iType
        $aOut[$iRow][$PT_R_TYPENAME]   = _PTBurn_RobotTypeName($iType)
        $iRow += 1
        $i   += 1
    WEnd

    ; Fallback: if RobotList is empty (hardware not detected, service just started,
    ; or robot temporarily offline), scan the Status directory for robot status files.
    ; PTBurnService names each file after the robot (e.g. "Disc Publisher 4200 XRP.txt")
    ; and writes RobotType under [System] in that file — enough to reconstruct a robot
    ; row so the GUI can still display job history while the hardware is absent.
    ; SystemStatus.txt itself is excluded; so are any files without a [System] section.
    If $iRow = 0 And $g_sPTBurn_StatusDir <> "" Then
        Local $hSearch = FileFindFirstFile($g_sPTBurn_StatusDir & "\*.txt")
        If $hSearch <> -1 Then
            While 1
                Local $sFile = FileFindNextFile($hSearch)
                If @error Then ExitLoop
                If StringLower($sFile) = "systemstatus.txt" Then ContinueLoop
                Local $sFullPath = $g_sPTBurn_StatusDir & "\" & $sFile
                ; Only treat as a robot file if it has a [System] section with RoboFWVer
                Local $sFW = IniRead($sFullPath, "System", "RoboFWVer", "")
                If $sFW = "" Then ContinueLoop
                Local $sRobotName = StringTrimRight($sFile, 4)   ; strip .txt
                Local $iType = Int(IniRead($sFullPath, "System", "RobotType", "3"))
                ReDim $aOut[$iRow + 1][$PT_R_FIELDS]
                $aOut[$iRow][$PT_R_NAME]       = $sRobotName
                $aOut[$iRow][$PT_R_STATUSFILE] = $sFullPath
                $aOut[$iRow][$PT_R_TYPE]       = $iType
                $aOut[$iRow][$PT_R_TYPENAME]   = _PTBurn_RobotTypeName($iType)
                $iRow += 1
            WEnd
            FileClose($hSearch)
        EndIf
    EndIf

    Return $aOut
EndFunc

Func _PTBurn_RobotTypeName($iType)
    Switch $iType
        Case $PTBURN_ROBOT_DP
            Return "Disc Publisher"
        Case $PTBURN_ROBOT_DPII
            Return "Disc Publisher II"
        Case $PTBURN_ROBOT_DPPRO
            Return "Disc Publisher Pro"
        Case $PTBURN_ROBOT_RACKMOUNT_DPII   ; = DPXR = 4
            Return "Disc Publisher XR"
        Case $PTBURN_ROBOT_DPXRP
            Return "Disc Publisher XRP"
        Case $PTBURN_ROBOT_DPSE
            Return "Disc Publisher SE"
        Case $PTBURN_ROBOT_DPPRO_XI
            Return "Disc Publisher Pro Xi"
        Case $PTBURN_ROBOT_DP_4100
            Return "Disc Publisher 4100"
        Case $PTBURN_ROBOT_DP_4100_XRP
            Return "Disc Publisher 4100 XRP"
        Case $PTBURN_ROBOT_DP_4051
            Return "Disc Publisher 4051"
        Case $PTBURN_ROBOT_DPSE3
            Return "Disc Publisher SE-3"
        Case $PTBURN_ROBOT_DP_4200
            Return "Disc Publisher 4200"
        Case $PTBURN_ROBOT_DP_4200_XRP
            Return "Disc Publisher 4200 XRP"
        Case $PTBURN_ROBOT_DP_4052
            Return "Disc Publisher 4052"
        Case Else
            Return "Unknown"
    EndSwitch
EndFunc

; Returns the PNG path for a robot's image, or "" if none found.
; The caller is responsible for converting the PNG to an HBITMAP for display —
; AutoIt's Pic control (SS_BITMAP) cannot load PNG files natively.  See
; _LoadPngAsHBITMAP() and _UpdateImage() in PTBurnStatusGUI.au3.
;
; Image mapping (from SDK zip Images/ folder):
;   DPII.png   — Disc Publisher II
;   DPSE.png   — Disc Publisher SE / SE-3
;   DPXRP.png  — Disc Publisher XRP, 4100 XRP, 4200 XRP
;   DPPRO.png  — Disc Publisher Pro, Pro Xi, 4200, 4051, 4052
;   DPXR.png   — Disc Publisher XR  (rackmount, RobotType 4)
;   DPXRn.png  — Disc Publisher 4100 / 4100-series (newer rack model)
;   NoneFound.png — fallback for unrecognised types
Func _PTBurn_GetRobotImage($aRobot)
    Local $sPng
    Switch $aRobot[$PT_R_TYPE]
        Case $PTBURN_ROBOT_DPII
            $sPng = $g_sPTBurn_ImagesDir & "\DPII.png"
        Case $PTBURN_ROBOT_DPSE, $PTBURN_ROBOT_DPSE3
            $sPng = $g_sPTBurn_ImagesDir & "\DPSE.png"
        Case $PTBURN_ROBOT_DPXRP, $PTBURN_ROBOT_DP_4200_XRP
            $sPng = $g_sPTBurn_ImagesDir & "\DPXRP.png"
        Case $PTBURN_ROBOT_DP_4100_XRP
            ; 4100 XRP is a rack-mount XRP variant — use DPXRn (4100 rack image)
            ; if available, otherwise fall back to DPXRP.
            Local $s4100xrp = $g_sPTBurn_ImagesDir & "\DPXRn.png"
            If FileExists($s4100xrp) Then
                $sPng = $s4100xrp
            Else
                $sPng = $g_sPTBurn_ImagesDir & "\DPXRP.png"
            EndIf
        Case $PTBURN_ROBOT_DP_4100, $PTBURN_ROBOT_DP_4051
            ; DPXRn.png is the 4100-series rack image shipped in the SDK v3.4.4 zip.
            $sPng = $g_sPTBurn_ImagesDir & "\DPXRn.png"
        Case $PTBURN_ROBOT_DPPRO, $PTBURN_ROBOT_DPPRO_XI, _
             $PTBURN_ROBOT_DP_4200, $PTBURN_ROBOT_DP_4052
            $sPng = $g_sPTBurn_ImagesDir & "\DPPRO.png"
        Case $PTBURN_ROBOT_RACKMOUNT_DPII   ; = DPXR = 4
            $sPng = $g_sPTBurn_ImagesDir & "\DPXR.png"
        Case Else
            $sPng = $g_sPTBurn_ImagesDir & "\NoneFound.png"
    EndSwitch
    If FileExists($sPng) Then Return $sPng
    Return ""
EndFunc

; ============================================================================
; BINS
; ============================================================================
Func _PTBurn_GetBins($aRobot)
    ; Returns a 3-element array: [Left count, Right count, HasRightBin]
    ; PDF §3.1.3.6/7: "If this value is -1 then the number is unknown."
    ; An absent key (IniRead returns our default "9999") means the robot does
    ; not have that bin — per SDK C# source which uses 9999 as the missing-key
    ; sentinel.  255 is the C# parse-error fallback; all three map to "?".
    ; Callers should hide the Right bin display when $aOut[$PT_B_HASRIGHT] = False.
    Local $aOut[3]
    Local $sName = $aRobot[$PT_R_NAME]
    Local $l = IniRead($g_sPTBurn_SystemFile, $sName, "DiscsInLeftBin",  "9999")
    Local $r = IniRead($g_sPTBurn_SystemFile, $sName, "DiscsInRightBin", "9999")

    ; Right bin absent from INI → single-bin robot
    Local $bHasRight = ($r <> "9999")
    $aOut[$PT_B_HASRIGHT] = $bHasRight

    If $l = "" Or $l = "-1" Or $l = "9999" Or $l = "255" Then $l = "?"
    If $r = "" Or $r = "-1" Or $r = "9999" Or $r = "255" Then $r = "?"

    $aOut[$PT_B_LEFT]  = $l
    $aOut[$PT_B_RIGHT] = $r
    Return $aOut
EndFunc

; ============================================================================
; CARTRIDGES
; ============================================================================
; PDF §3.1.3.8 documents the INI slot layout:
;
; Standard robots (single COLOR + BLACK):
;   CartridgeType0 / CartridgeFill0 = Black (type 2)
;   CartridgeType1 / CartridgeFill1 = Color (type 1)
;
; 4-tank robots (individual Y/C/M, e.g. Bravo 4100):
;   CartridgeType0 / CartridgeFill0 = Black   (type 2)
;   CartridgeType1 / CartridgeFill1 = Color   (type 1) — lowest of Y/C/M, for compatibility
;   CartridgeType2 / CartridgeFill2 = Yellow  (type 3)
;   CartridgeType3 / CartridgeFill3 = Cyan    (type 4)
;   CartridgeType4 / CartridgeFill4 = Magenta (type 5)
;   Presence of CartridgeType4 signals individual-tank mode.
;
; Lotus-cartridge robots (DP 4200/SE-3):
;   CartridgeType0 / CartridgeFill0 = ColorLotus (type 6) — sole cartridge
;
; Each type code is self-identifying, so _PTBurn_CartName() labels them
; correctly regardless of slot order.
Func _PTBurn_GetCartridges($aRobot)
    Local $aOut[0][$PT_C_FIELDS]
    Local $sFile = $g_sPTBurn_SystemFile
    Local $sName = $aRobot[$PT_R_NAME]

    Local $aType[5], $aFill[5]
    For $i = 0 To 4
        $aType[$i] = IniRead($sFile, $sName, "CartridgeType" & $i, "")
        $aFill[$i] = IniRead($sFile, $sName, "CartridgeFill" & $i, "")
    Next

    Local $bIndividual = ($aType[4] <> "")

    ; Slot 0 (Black on individual-tank models, or sole cartridge)
    If $aType[0] <> "" And $aType[0] <> "0" Then
        _PTBurn_AddCart($aOut, $aType[0], $aFill[0])
    EndIf

    If $bIndividual Then
        ; Per SDK comment: slots 2,3,4 are Y/C/M when individual tanks present
        For $i = 2 To 4
            If $aType[$i] <> "" And $aType[$i] <> "0" Then
                _PTBurn_AddCart($aOut, $aType[$i], $aFill[$i])
            EndIf
        Next
    Else
        ; Combined COLOR cartridge in slot 1
        If $aType[1] <> "" And $aType[1] <> "0" Then
            _PTBurn_AddCart($aOut, $aType[1], $aFill[1])
        EndIf
    EndIf

    Return $aOut
EndFunc

Func _PTBurn_AddCart(ByRef $aOut, $sType, $sFill)
    Local $iRow = UBound($aOut)
    ReDim $aOut[$iRow + 1][$PT_C_FIELDS]
    $aOut[$iRow][$PT_C_NAME] = _PTBurn_CartName($sType)
    If $sFill = "" Then
        $aOut[$iRow][$PT_C_FILL] = 0
    Else
        $aOut[$iRow][$PT_C_FILL] = Number($sFill)
    EndIf
EndFunc

Func _PTBurn_CartName($sType)
    Switch Int($sType)
        Case 1
            Return "Color"
        Case 2
            Return "Black"
        Case 3
            Return "Yellow"
        Case 4
            Return "Cyan"
        Case 5
            Return "Magenta"
        Case 6   ; CARTRIDGE_COLORLOTUS — PDF §3.1.3.8 (added doc rev 3.2.5).
                 ; Single combined color+black cartridge used on DP 4200/SE-3.
                 ; The SDK CartridgeType enum only goes to 5; type 6 was added
                 ; with the 4200 and is confirmed in PTBurnHistory v3.4.3.
                 ; Label "Color+Black" to remind users this single bar represents
                 ; both ink levels, not just color.
            Return "Color+Black"
        Case Else
            Return "None"
    EndSwitch
EndFunc

Func _PTBurn_CartColor($iPct)
    If $iPct >= $PTBURN_CART_OK_PCT Then Return $PTBURN_COL_OK
    If $iPct >= $PTBURN_CART_WARN_PCT Then Return $PTBURN_COL_WARN
    Return $PTBURN_COL_BAD
EndFunc

; ============================================================================
; DRIVES
; ============================================================================
Func _PTBurn_GetDrives($aRobot)
    Local $aOut[0][$PT_D_FIELDS]
    Local $sFile = $aRobot[$PT_R_STATUSFILE]
    If Not FileExists($sFile) Then Return $aOut

    ; SDK StatusFile.RefreshDrives() uses an unbounded while loop breaking on the
    ; first absent DriveLocation key — no hard cap on drive count.
    Local $iRow = 0, $i = 0
    While 1
        Local $sLoc = IniRead($sFile, "System", "DriveLocation" & $i, "")
        If $sLoc = "" Then ExitLoop

        Local $sDesc = IniRead($sFile, "System", "DriveDesc"     & $i, "")
        Local $sStat = IniRead($sFile, "System", "DriveState"    & $i, "0")
        Local $sPct  = IniRead($sFile, "System", "DrivePercent"  & $i, "0")
        Local $sJob  = IniRead($sFile, "System", "DriveJob"      & $i, "")
        Local $sDisc = IniRead($sFile, "System", "DriveDisc"     & $i, "")

        Local $iPct
        If $sPct = "None" Or $sPct = "" Then
            $iPct = 0
        Else
            $iPct = Number($sPct)
        EndIf
        If $iPct < 0 Then $iPct = 0
        If $iPct > 100 Then $iPct = 100

        If $sDisc = "None" Then $sDisc = ""

        ReDim $aOut[$iRow + 1][$PT_D_FIELDS]
        $aOut[$iRow][$PT_D_DESC]      = $sDesc
        $aOut[$iRow][$PT_D_LOCATION]  = $sLoc
        $aOut[$iRow][$PT_D_STATE]     = Int($sStat)
        $aOut[$iRow][$PT_D_STATETEXT] = _PTBurn_DriveStateText(Int($sStat))
        $aOut[$iRow][$PT_D_PERCENT]   = $iPct
        $aOut[$iRow][$PT_D_JOB]       = $sJob
        $aOut[$iRow][$PT_D_DISC]      = $sDisc
        $iRow += 1
        $i    += 1
    WEnd
    Return $aOut
EndFunc

Func _PTBurn_DriveStateText($i)
    Switch $i
        Case $PTBURN_DRV_IDLE
            Return "Idle"
        Case $PTBURN_DRV_RECORDING
            Return "Recording"
        Case $PTBURN_DRV_READING
            Return "Reading"
        Case $PTBURN_DRV_VERIFYING
            Return "Verifying"
        Case $PTBURN_DRV_DISC_LOADED
            Return "Disc Loaded"
        Case $PTBURN_DRV_VERIFY_FAILED
            Return "Verify Failed"
        Case $PTBURN_DRV_VERIFY_COMPLETE
            Return "Verify Complete"
        Case $PTBURN_DRV_RECORD_FAILED
            Return "Record Failed"
        Case $PTBURN_DRV_RECORD_COMPLETE
            Return "Record Complete"
        Case Else
            Return "Idle"
    EndSwitch
EndFunc

; ============================================================================
; JOBS
; ============================================================================
; Newer PTBurn builds (e.g. DP 4200) no longer write [JobList]/[CompletedJobs]
; sections to the status file. Instead, jobs live as files in PTBurnJobs:
;   <name>.JRQ   - active/queued job request
;   <name>.ERR   - failed job (renamed JRQ)
; Successful jobs are deleted on completion, so they are not listed here.
;
; .JRQ/.ERR files use "Key = Value" lines (with spaces around =), not standard
; INI sections, so we parse them manually.
Func _PTBurn_GetJobs($aRobot)
    Local $aOut[0][$PT_J_FIELDS]

    ; Modern path first — file-scan entries carry JobTitle and exact state.
    ; Track which filename stems were added so the legacy path can skip dupes.
    Local $aSeenStems[0]
    _PTBurn_ScanJobFolderTracked($aOut, $aSeenStems)

    ; Back-fill disc counts and live status from the status INI for all file-scan jobs.
    ; The .DON/.ERR/.INP/.JRQ files are the original job submission files — PTBurnService
    ; renames them as the job progresses but does NOT write GoodDiscs, CurrentStatus, or
    ; any completion data back into them.  All of that only exists in the per-job section
    ; of RobotName.txt (e.g. [10FD00_MicrosoftVisualStudio2022]).
    ;
    ; When the INI has fresh data for a completed job we also write it to the local cache
    ; (PTBurnJobCache.ini, last 99 jobs).  When the INI section has been rotated out we
    ; fall back to the cache so Good/Bad counts survive PTBurnService's rotation window.
    Local $sFile = $aRobot[$PT_R_STATUSFILE]
    If FileExists($sFile) Then
        Local $iCount = UBound($aOut)
        For $i = 0 To $iCount - 1
            Local $sStem = $aOut[$i][$PT_J_STEM]
            If $sStem = "" Then ContinueLoop

            ; IniRead uses the stem as the section name (same as legacy path)
            Local $iGood  = Int(IniRead($sFile, $sStem, "GoodDiscs",          "-1"))
            Local $iBad   = Int(IniRead($sFile, $sStem, "BadDiscs",           "-1"))
            Local $iRem   = Int(IniRead($sFile, $sStem, "DiscsRemaining",     "-1"))
            Local $sStat  = IniRead($sFile, $sStem, "CurrentStatus",          "")
            Local $sErr   = IniRead($sFile, $sStem, "JobErrorString",         "")
            Local $iSState = Int(IniRead($sFile, $sStem, "CurrentStatusState","-1"))
            Local $sTimeCompleted = IniRead($sFile, $sStem, "TimeCompleted",  "")

            Local $bHaveLiveData = ($iGood >= 0 Or $iBad >= 0 Or $sStat <> "" Or $sErr <> "")

            If $bHaveLiveData Then
                ; --- INI section is present: apply values and update the cache --------
                If $iGood >= 0 Then $aOut[$i][$PT_J_GOOD]      = $iGood
                If $iBad  >= 0 Then $aOut[$i][$PT_J_BAD]       = $iBad
                If $iRem  >= 0 Then $aOut[$i][$PT_J_REMAINING] = $iRem

                ; Error string takes highest priority, then CurrentStatus from INI,
                ; then CurrentStatusState from INI, then preserve whatever
                ; _PTBurn_AddJobFromFile already parsed from the job file itself.
                If $sErr <> "" Then
                    $aOut[$i][$PT_J_STATUS] = $sErr
                ElseIf $sStat <> "" Then
                    $aOut[$i][$PT_J_STATUS] = $sStat
                ElseIf $iSState >= 0 Then
                    Local $sStateStr = _PTBurn_StatusStateText($iSState)
                    If $sStateStr <> "" Then $aOut[$i][$PT_J_STATUS] = $sStateStr
                EndIf

                ; Write to cache for completed/failed/moved jobs only — no point
                ; caching an in-progress status that will change next refresh.
                Local $iJobState = $aOut[$i][$PT_J_STATE]
                If $iJobState = $PTBURN_JOB_COMPLETED Or _
                   $iJobState = $PTBURN_JOB_FAILED    Or _
                   $iJobState = $PTBURN_JOB_MOVED     Then
                    Local $sCacheStatus = $aOut[$i][$PT_J_STATUS]
                    If $sErr <> "" Then $sCacheStatus = $sErr
                    _PTBurn_CacheWrite($sStem, $aOut[$i][$PT_J_NAME], _
                            $aOut[$i][$PT_J_GOOD], $aOut[$i][$PT_J_BAD], _
                            $sCacheStatus, $sTimeCompleted)
                EndIf
            Else
                ; --- INI section absent (rotated out): try the local cache -----------
                _PTBurn_CacheRead($sStem, $aOut, $i)
            EndIf
        Next
    EndIf

    ; Legacy path: only add entries whose stem was NOT already found above.
    ; This prevents the same job appearing twice on newer robots (e.g. DP 4200)
    ; that write both a status-file section AND a .DON/.INP file for the same job.
    If FileExists($sFile) Then
        _PTBurn_AddJobsLegacyFiltered($aOut, $sFile, "CompletedJobs", True,  $aSeenStems)
        _PTBurn_AddJobsLegacyFiltered($aOut, $sFile, "JobList",       False, $aSeenStems)
    EndIf

    Return $aOut
EndFunc

; Filtered replacement for _PTBurn_AddJobsLegacy — skips any job whose filename
; stem already appears in $aSeenStems (populated by the file-scan pass above).
; Uses an unbounded While loop matching SDK StatusFile.RefreshJobs() pattern —
; exits on the first absent Job<n> key rather than relying on an arbitrary cap.
Func _PTBurn_AddJobsLegacyFiltered(ByRef $aOut, $sFile, $sSection, $bCompleted, ByRef $aSeenStems)
    Local $i = 0
    While 1
        Local $sJob = IniRead($sFile, $sSection, "Job" & $i, "")
        If $sJob = "" Then ExitLoop
        $i += 1

        ; Skip if file-scan already added this job.
        ; Both sides are lowercased: $aSeenStems entries were lowercased during
        ; _PTBurn_ScanExtTracked, and we lowercase $sJob here to match.
        ; Windows filenames are case-insensitive, so "MyJob" and "myjob" are the
        ; same stem — without this, the same job could appear twice if the INI
        ; section name differs in case from the filename on disk.
        Local $sJobLower = StringLower($sJob)
        Local $bSeen = False
        For $j = 0 To UBound($aSeenStems) - 1
            If $aSeenStems[$j] = $sJobLower Then
                $bSeen = True
                ExitLoop
            EndIf
        Next
        If $bSeen Then ContinueLoop

        Local $iState = Int(IniRead($sFile, $sJob, "JobState",       "0"))
        Local $iGood  = Int(IniRead($sFile, $sJob, "GoodDiscs",      "0"))
        Local $iBad   = Int(IniRead($sFile, $sJob, "BadDiscs",       "0"))
        Local $iRem   = Int(IniRead($sFile, $sJob, "DiscsRemaining", "0"))
        Local $sStat  = IniRead($sFile, $sJob, "CurrentStatus",      "")
        Local $sErr   = IniRead($sFile, $sJob, "JobErrorString",     "")

        If $sStat = "" And $sErr <> "" Then $sStat = $sErr
        If $sStat = "" Then $sStat = _PTBurn_JobStateText($iState)

        ; Derive completed flag from actual JobState, not just the section it came from.
        ; CompletedJobs section can still contain running jobs during a race condition,
        ; and JobList can contain jobs that already have JobState=2/3/4.
        Local $bDone = ($iState = $PTBURN_JOB_COMPLETED Or _
                        $iState = $PTBURN_JOB_FAILED    Or _
                        $iState = $PTBURN_JOB_MOVED)
        ; If JobState was not written yet (0 = not started) but it came from CompletedJobs,
        ; trust the section as a fallback.
        If $iState = $PTBURN_JOB_NOT_STARTED And $bCompleted Then $bDone = True

        Local $iRow = UBound($aOut)
        ReDim $aOut[$iRow + 1][$PT_J_FIELDS]
        $aOut[$iRow][$PT_J_NAME]      = $sJob
        $aOut[$iRow][$PT_J_STATE]     = $iState
        $aOut[$iRow][$PT_J_STATETEXT] = _PTBurn_JobStateText($iState)
        $aOut[$iRow][$PT_J_GOOD]      = $iGood
        $aOut[$iRow][$PT_J_BAD]       = $iBad
        $aOut[$iRow][$PT_J_REMAINING] = $iRem
        $aOut[$iRow][$PT_J_STATUS]    = $sStat
        $aOut[$iRow][$PT_J_COMPLETED] = $bDone
        $aOut[$iRow][$PT_J_STEM]      = $sJob   ; section name = filename stem

        ; Cache completed/failed/moved jobs from the legacy INI path so their
        ; Good/Bad counts survive future [CompletedJobs] rotation.
        If $bDone Then
            Local $sTimeComp = IniRead($sFile, $sJob, "TimeCompleted", "")
            _PTBurn_CacheWrite($sJob, $sJob, $iGood, $iBad, $sStat, $sTimeComp)
        EndIf

        ; Record this stem so a second call (e.g. JobList after CompletedJobs)
        ; doesn't add the same job again.  Race condition described in PTBurn
        ; docs: a job can momentarily appear in both sections during state
        ; transitions.  Without this, the GUI would show duplicate rows.
        ReDim $aSeenStems[UBound($aSeenStems) + 1]
        $aSeenStems[UBound($aSeenStems) - 1] = $sJobLower
    WEnd
EndFunc

; Kept for backward compatibility — wraps the tracked version.
Func _PTBurn_AddJobsLegacy(ByRef $aOut, $sFile, $sSection, $bCompleted)
    Local $aIgnored[0]
    _PTBurn_AddJobsLegacyFiltered($aOut, $sFile, $sSection, $bCompleted, $aIgnored)
EndFunc

Func _PTBurn_ScanJobFolder(ByRef $aOut)
    Local $aIgnored[0]
    _PTBurn_ScanJobFolderTracked($aOut, $aIgnored)
EndFunc

; Scans all job-file extensions and records each filename stem in $aSeenStems.
; All five extensions are confirmed in the SDK:
;   .JRQ — client submitted (PDF §3, PTBurnHistory throughout)
;   .QRJ — PTBurn has discovered and queued the job (PDF §3; PTBurnHistory 3.2.5
;           explicitly mentions KillAllIncludingJRQ covering "JRQ and QRJ")
;   .INP — currently processing (PDF §3)
;   .DON — completed successfully (PDF §3)
;   .ERR — failed or aborted (PDF §3)
; .DON/.ERR files are deleted after Status_Time minutes (default 60) per PTSETUP.INI.
;
; Ordering: newest-first overall.  Within each extension, files are sorted by
; modification time descending (_ScanExtTracked).  Extensions are visited in
; "most recent activity first" order: active jobs (JRQ submitted, QRJ queued,
; INP processing) come before terminal states (DON complete, ERR failed) so
; the user sees current work at the top of the list.
Func _PTBurn_ScanJobFolderTracked(ByRef $aOut, ByRef $aSeenStems)
    _PTBurn_ScanExtTracked($aOut, $aSeenStems, "INP", $PTBURN_JOB_RUNNING,     "Processing")
    _PTBurn_ScanExtTracked($aOut, $aSeenStems, "QRJ", $PTBURN_JOB_QUEUED,      "Queued")
    _PTBurn_ScanExtTracked($aOut, $aSeenStems, "JRQ", $PTBURN_JOB_NOT_STARTED, "Submitted")
    _PTBurn_ScanExtTracked($aOut, $aSeenStems, "ERR", $PTBURN_JOB_FAILED,      "Error")
    _PTBurn_ScanExtTracked($aOut, $aSeenStems, "DON", $PTBURN_JOB_COMPLETED,   "Complete")
EndFunc

Func _PTBurn_ScanExt(ByRef $aOut, $sExt, $iState, $sStateText)
    Local $aIgnored[0]
    _PTBurn_ScanExtTracked($aOut, $aIgnored, $sExt, $iState, $sStateText)
EndFunc

Func _PTBurn_ScanExtTracked(ByRef $aOut, ByRef $aSeenStems, $sExt, $iState, $sStateText)
    Local $aList = _FileListToArray($g_sPTBurn_JobsRoot, "*." & $sExt, 1, False)
    If @error Then Return

    ; Sort by modification time descending — newest files first within this
    ; extension group.  _FileListToArray returns names only, so we pair each
    ; with FileGetTime() and bubble-sort descending.  Job counts per extension
    ; are small (typically <50), so O(n^2) is acceptable here.
    Local $iN = $aList[0]
    If $iN > 1 Then
        Local $aTimes[$iN + 1]
        For $k = 1 To $iN
            ; FileGetTime mode 1 returns YYYYMMDDHHMMSS string; "" on failure.
            ; @error is set on failure; we leave the slot empty so it sorts last.
            Local $sT = FileGetTime($g_sPTBurn_JobsRoot & "\" & $aList[$k], 0, 1)
            If @error Then
                $aTimes[$k] = ""
            Else
                $aTimes[$k] = $sT
            EndIf
        Next
        ; Bubble-sort descending by mtime — small N (typically <50 per extension)
        For $k = 1 To $iN - 1
            For $m = 1 To $iN - $k
                If $aTimes[$m] < $aTimes[$m + 1] Then
                    Local $sTmpT = $aTimes[$m]
                    Local $sTmpF = $aList[$m]
                    $aTimes[$m]     = $aTimes[$m + 1]
                    $aList[$m]      = $aList[$m + 1]
                    $aTimes[$m + 1] = $sTmpT
                    $aList[$m + 1]  = $sTmpF
                EndIf
            Next
        Next
    EndIf

    For $i = 1 To $aList[0]
        Local $sStem = StringLower(StringRegExpReplace($aList[$i], "\.[A-Za-z]{3}$", ""))
        _PTBurn_AddJobFromFile($aOut, $g_sPTBurn_JobsRoot & "\" & $aList[$i], _
                $iState, $sStateText)
        ReDim $aSeenStems[UBound($aSeenStems) + 1]
        $aSeenStems[UBound($aSeenStems) - 1] = $sStem
    Next
EndFunc

; Parses a job file.  The SDK (JobFile.cs SendJobFile) writes lines as "Key=Value"
; with no spaces around '='.  The regex below also accepts "Key = Value" defensively,
; since some older or third-party job generators may include spaces.
; Extracts JobTitle, Job ID, disc counts, CurrentStatus, CurrentStatusState, and error text.
Func _PTBurn_AddJobFromFile(ByRef $aOut, $sPath, $iState, $sStateText)
    Local $sName = StringRegExpReplace($sPath, "^.*\\", "")
    $sName = StringRegExpReplace($sName, "\.[A-Za-z]{3}$", "")

    Local $sTitle      = ""
    Local $sJobID      = ""
    Local $sStatus     = ""
    Local $iStatusState = -1   ; CurrentStatusState numeric value (-1 = not present)
    Local $iGood       = 0
    Local $iBad        = 0
    Local $iRem        = 0

    ; Open with the correct encoding for the installed PTBurnService build.
    ; Unicode build writes job files (.JRQ/.QRJ/.INP/.DON/.ERR) as UTF-16 LE
    ; with a BOM — FileOpen mode 0 (ANSI) would read the null bytes between each
    ; UTF-16 code unit as garbage, causing all key matches to fail silently.
    ; Mode 32 ($FO_UNICODE) tells AutoIt to expect UTF-16 LE with a BOM.
    ;
    ; NOTE: IniRead (used elsewhere for .txt status files) does NOT need the same
    ; treatment — it wraps GetPrivateProfileStringW which detects the UTF-16 LE
    ; BOM automatically and switches to Unicode mode on its own.  Only the manual
    ; FileOpen/FileReadLine path here requires explicit mode selection.
    ; Mode 0 = ANSI (MBCS build); mode 32 = $FO_UNICODE / UTF-16 LE (Unicode build).
    Local $iOpenMode
    If $g_bPTBurn_Unicode Then
        $iOpenMode = 32
    Else
        $iOpenMode = 0
    EndIf
    Local $hFile = FileOpen($sPath, $iOpenMode)
    If $hFile = -1 Then
        ; PTBurnService may hold the file open briefly while writing.
        ; One retry after a short wait covers the vast majority of transient locks.
        Sleep(100)
        $hFile = FileOpen($sPath, $iOpenMode)
    EndIf
    If $hFile <> -1 Then
        While 1
            Local $sLine = FileReadLine($hFile)
            If @error Then ExitLoop
            Local $aPair = StringRegExp($sLine, "^\s*([^=]+?)\s*=\s*(.*)\s*$", 1)
            If @error Then ContinueLoop
            Local $sKey = $aPair[0]
            Local $sVal = $aPair[1]
            Switch $sKey
                Case "JobTitle"
                    $sTitle = $sVal
                Case "Job ID", "JobID"
                    $sJobID = $sVal
                Case "CurrentStatus"
                    ; Live status string PTBurn updates as the job progresses
                    If $sStatus = "" Then $sStatus = $sVal
                Case "CurrentStatusState"
                    ; Numeric status code — SDK §3.2.4.20, values 0-17;
                    ; value 18 ("moved to another robot") added in v3.3.0.
                    $iStatusState = Int($sVal)
                Case "ErrorString", "JobErrorString"
                    ; Error string overrides CurrentStatus
                    $sStatus = $sVal
                Case "GoodDiscs"
                    $iGood = Int($sVal)
                Case "BadDiscs"
                    $iBad = Int($sVal)
                Case "DiscsRemaining"
                    $iRem = Int($sVal)
            EndSwitch
        WEnd
        FileClose($hFile)
    EndIf

    Local $sDisplay = $sTitle
    If $sDisplay = "" Then $sDisplay = $sJobID
    If $sDisplay = "" Then $sDisplay = $sName

    ; Build status string: prefer CurrentStatus from file; fall back to
    ; CurrentStatusState (translated) if status is blank or just the generic
    ; extension-derived text; finally fall back to the extension-derived text.
    If $sStatus = "" And $iStatusState >= 0 Then
        $sStatus = _PTBurn_StatusStateText($iStatusState)
    EndIf
    If $sStatus = "" Then $sStatus = $sStateText

    Local $iRow = UBound($aOut)
    ReDim $aOut[$iRow + 1][$PT_J_FIELDS]
    $aOut[$iRow][$PT_J_NAME]      = $sDisplay
    $aOut[$iRow][$PT_J_STATE]     = $iState
    $aOut[$iRow][$PT_J_STATETEXT] = $sStateText
    $aOut[$iRow][$PT_J_GOOD]      = $iGood
    $aOut[$iRow][$PT_J_BAD]       = $iBad
    $aOut[$iRow][$PT_J_REMAINING] = $iRem
    $aOut[$iRow][$PT_J_STATUS]    = $sStatus
    $aOut[$iRow][$PT_J_COMPLETED] = ($iState = $PTBURN_JOB_COMPLETED Or _
                                     $iState = $PTBURN_JOB_FAILED   Or _
                                     $iState = $PTBURN_JOB_MOVED)
    $aOut[$iRow][$PT_J_STEM]      = $sName   ; filename stem for abort command
EndFunc

; Translates CurrentStatusState numeric code (SDK §3.2.4.20) to a display string.
Func _PTBurn_StatusStateText($i)
    Switch $i
        Case 0  ; Recording Disc
            Return "Recording Disc"
        Case 1  ; Reading Disc
            Return "Reading Disc"
        Case 2  ; Verifying Disc
            Return "Verifying Disc"
        Case 3  ; Printing Disc
            Return "Printing Disc"
        Case 4  ; Loading Disc
            Return "Loading Disc"
        Case 5  ; Unloading Disc
            Return "Unloading Disc"
        Case 6  ; Waiting for Printer
            Return "Waiting for Printer"
        Case 7  ; Waiting for Recorder
            Return "Waiting for Recorder"
        Case 8  ; Finishing Disc
            Return "Finishing Disc"
        Case 9  ; Rejecting Disc
            Return "Rejecting Disc"
        Case 10 ; Job Complete
            Return "Complete"
        Case 11 ; Job Paused
            Return "Paused"
        Case 12 ; Job Resumed
            Return "Resumed"
        Case 13 ; Job Aborted
            Return "Aborted"
        Case 14 ; Job Initializing
            Return "Initializing"
        Case 15 ; Job Failed
            Return "Failed"
        Case 16 ; Pre-Mastering
            Return "Pre-Mastering"
        Case 17 ; System OK
            Return "System OK"
        Case 18 ; Job moved to another robot (added v3.3.0)
            Return "Moved to Another Robot"
        Case Else
            Return ""
    EndSwitch
EndFunc

Func _PTBurn_JobStateText($i)
    Switch $i
        Case $PTBURN_JOB_NOT_STARTED
            Return "Queued"
        Case $PTBURN_JOB_RUNNING
            Return "Running"
        Case $PTBURN_JOB_COMPLETED
            Return "Completed"
        Case $PTBURN_JOB_FAILED
            Return "Failed"
        Case $PTBURN_JOB_MOVED
            Return "Moved"
        Case $PTBURN_JOB_QUEUED
            Return "Queued"
        Case Else
            Return "Unknown"
    EndSwitch
EndFunc

; Takes state + completed flag and returns a background colour for the jobs ListView row.
; NOTE: $bCompleted is accepted for API symmetry with the job row data structure but is
; not used in the Switch — state alone fully determines the colour.  COMPLETED and MOVED
; jobs are both handled by the $PTBURN_JOB_COMPLETED/$PTBURN_JOB_MOVED case returning green.
Func _PTBurn_JobRowColor($iState, $bCompleted)
    Switch $iState
        Case $PTBURN_JOB_FAILED
            Return $PTBURN_COL_BAD       ; red
        Case $PTBURN_JOB_COMPLETED, $PTBURN_JOB_MOVED
            Return $PTBURN_COL_OK        ; green
        Case $PTBURN_JOB_RUNNING
            Return $PTBURN_COL_WARN      ; yellow
        Case $PTBURN_JOB_QUEUED
            Return $PTBURN_COL_INFO      ; blue
        Case Else
            Return $PTBURN_COL_WHITE     ; submitted / unknown
    EndSwitch
EndFunc

; ============================================================================
; SYSTEM INFO
; ============================================================================
; NOTE: _PTBurn_GetSystemInfo reads from the per-robot status file
; (e.g. \\server\PTBurnJobs\Status\Disc Publisher XRP.txt [System] section),
; NOT from SystemStatus.txt.  Fields like RoboFWVer, SerialNum, and DateManf
; only exist in the robot file; SystemStatus.txt carries only the high-level
; SysErrorString and SystemDrives keys for each robot.
; SysErrorNumber is present in both files.  We read the robot file first and
; fall back to the per-robot section of SystemStatus.txt if the robot file
; returns 0 — the service updates SystemStatus.txt first on each cycle, so
; this catches errors during the brief window before the robot file is updated.
Func _PTBurn_GetSystemInfo($aRobot)
    Local $aOut[6]
    Local $sFile = $aRobot[$PT_R_STATUSFILE]
    $aOut[$PT_S_FW]       = IniRead($sFile, "System", "RoboFWVer",      "")
    $aOut[$PT_S_SERIAL]   = IniRead($sFile, "System", "SerialNum",      "")
    $aOut[$PT_S_MANFDATE] = IniRead($sFile, "System", "DateManf",       "")
    $aOut[$PT_S_STATUS]   = IniRead($sFile, "System", "SystemStatus",   "")
    $aOut[$PT_S_ERROR]    = IniRead($sFile, "System", "SysErrorString", "")
    $aOut[$PT_S_ERRNUM]   = Int(IniRead($sFile, "System", "SysErrorNumber", "0"))

    ; Cross-check SysErrorNumber against SystemStatus.txt's per-robot section.
    ; If the robot file has not yet been updated after a new error, SystemStatus.txt
    ; carries the more recent value.  Take whichever is non-zero.
    If $aOut[$PT_S_ERRNUM] = 0 And $g_sPTBurn_SystemFile <> "" Then
        Local $iSysNum = Int(IniRead($g_sPTBurn_SystemFile, $aRobot[$PT_R_NAME], "SysErrorNumber", "0"))
        If $iSysNum <> 0 Then
            $aOut[$PT_S_ERRNUM] = $iSysNum
            ; Also pull the error string from SystemStatus.txt if the robot file had none.
            If $aOut[$PT_S_ERROR] = "" Then
                $aOut[$PT_S_ERROR] = IniRead($g_sPTBurn_SystemFile, $aRobot[$PT_R_NAME], "SysErrorString", "")
            EndIf
        EndIf
    EndIf

    Return $aOut
EndFunc

; ============================================================================
; COMMANDS  (drop .ptm files into \\server\PTBurnJobs\)
; ============================================================================

; Internal helper — opens a .ptm file for writing with the correct encoding.
; PTBurnHistory.txt: .PTM files MUST be Unicode when running the Unicode build.
; FileOpen mode 2 = overwrite; mode 34 = overwrite + UTF-16 LE BOM (AutoIt
; $FO_OVERWRITE + $FO_UNICODE, values 2 and 32).
Func _PTBurn_OpenPtm($sPath)
    If $g_bPTBurn_Unicode Then
        Return FileOpen($sPath, 2 + 32)   ; overwrite, UTF-16 LE
    Else
        Return FileOpen($sPath, 2)        ; overwrite, ANSI
    EndIf
EndFunc

; Internal helper — returns a unique .ptm path that does not currently exist.
; Uses a pseudo-random name to avoid the TOCTOU race inherent in the sequential
; "Message (n).ptm" scheme: two concurrent clients checking FileExists() could
; both resolve to the same filename before either writes.
; Format: Msg_<8 hex of timer+PID>_<4 random hex>.ptm
;
; Entropy budget: the timer-derived seed gives ~32 bits but two near-simultaneous
; calls (within the same Int(TimerInit()) quantum) collapse to the same seed,
; so realistic per-pair collision probability is ~1/65536 from the 16-bit random
; tail.  That's why the FileExists retry loop exists — it catches the rare
; collision and tries again with a fresh random.  20 attempts is generous.
Func _PTBurn_UniquePtmPath()
    Local $sBase
    Local $iTries = 0
    Do
        ; TimerInit() returns an opaque QueryPerformanceCounter-derived value;
        ; it is monotonic and provides some entropy but is NOT a wall-clock time.
        ; Hex(N, 8) keeps only the low 32 bits, which is enough here.
        Local $iSeed = BitXOR(Int(TimerInit()) * 65537, @AutoItPID * 7)
        Local $sHex1 = Hex($iSeed, 8)
        Local $sHex2 = Hex(Random(0, 0xFFFF, 1), 4)
        $sBase = $g_sPTBurn_JobsRoot & "\Msg_" & $sHex1 & "_" & $sHex2 & ".ptm"
        $iTries += 1
        If $iTries > 20 Then Return ""   ; share may be full or unreachable
    Until Not FileExists($sBase)
    Return $sBase
EndFunc

Func _PTBurn_SendMessage($aRobot, $sMessage)
    ; Mirrors SampleClient.Form1.buttonSendMsg_Click.
    ; Uses a unique GUID-derived filename to avoid TOCTOU races when multiple
    ; clients write message files concurrently.
    Local $sFile = _PTBurn_UniquePtmPath()
    If $sFile = "" Then Return SetError(1, 0, False)

    Local $hF = _PTBurn_OpenPtm($sFile)
    If $hF = -1 Then Return SetError(1, 0, False)
    FileWriteLine($hF, "Message=" & $sMessage)
    FileWriteLine($hF, "ClientID=Administrator")
    FileWriteLine($hF, "RobotName=" & $aRobot[$PT_R_NAME])
    FileClose($hF)
    Return True
EndFunc

Func _PTBurn_AbortJob($aRobot, $sJobName)
    ; Mirrors PTBurnStatusCtrl.buttonSendJobAction_Click for the Abort case.
    ; SDK explicitly checks !File.Exists(jobFile) before writing — we must not
    ; overwrite a .ptm that PTBurn may already be reading.
    If $sJobName = "" Then Return SetError(2, 0, False)
    ; Sanitize stem — strip path separators and Windows reserved characters.
    ; Note: dots are NOT stripped (so ".." sequences survive), but the stem comes
    ; from a filename already present on the PTBurnJobs share, which the service
    ; never writes with traversal components.  Defensive guard against future
    ; callers that might pass user-supplied names.
    Local $sSafe = StringRegExpReplace($sJobName, '[\\/:*?"<>|]', "")
    If $sSafe = "" Then Return SetError(4, 0, False)
    Local $sFile = $g_sPTBurn_JobsRoot & "\" & $sSafe & ".ptm"
    If FileExists($sFile) Then Return SetError(3, 0, False)  ; SDK: skip if already pending
    Local $hF = _PTBurn_OpenPtm($sFile)
    If $hF = -1 Then Return SetError(1, 0, False)
    FileWriteLine($hF, "Message=ABORT")
    FileWriteLine($hF, "ClientID=Administrator")
    FileWriteLine($hF, "RobotName=" & $aRobot[$PT_R_NAME])
    FileClose($hF)
    Return True
EndFunc

; PDF §4.5: Dismisses an ink-low system error (SysErrorNumber 5, 6, or 7) so
; the robot continues working without requiring physical intervention.
; Only valid on Disc Publisher PRO, XRP, SE and their derivatives.
; NOTE: like Check Bins, this command only works when there are no jobs currently
; in the system.  The GUI shows this button only when the ink-low error is present,
; which typically means the robot has already paused — so no jobs should be running.
; Sends IGNORE_INKLOW for the specified robot.
; PDF §4.5: valid when SysErrorNumber is 5 (color low), 6 (black low), or 7 (both).
; Deliberate deviation: PDF §4.5 lists only Message= and ClientID=, but we also
; write RobotName= so multi-robot deployments target the correct unit.  Unknown
; keys are ignored by PTBurnService, so this is safe on single-robot setups too.
Func _PTBurn_SendIgnoreInkLow($aRobot)
    Local $sFile = _PTBurn_UniquePtmPath()
    If $sFile = "" Then Return SetError(1, 0, False)
    Local $hF = _PTBurn_OpenPtm($sFile)
    If $hF = -1 Then Return SetError(1, 0, False)
    FileWriteLine($hF, "Message=IGNORE_INKLOW")
    FileWriteLine($hF, "ClientID=Administrator")
    FileWriteLine($hF, "RobotName=" & $aRobot[$PT_R_NAME])
    FileClose($hF)
    Return True
EndFunc
