#cs
    PTBurn Disc Status Monitor
    --------------------------
    Standalone AutoIt GUI replicating the Status tab of Primera's PTDevSuite
    SampleClient.exe (based on PTBurn SDK v3.3.4, extended for v3.4.x hardware
    including the DP 4200 XRP), with usability improvements.

    All PTBurn data access lives in PTBurnSDK.au3 (same folder).
    Robot images are expected in .\Images\ (DPII.png, DPSE.png, DPXRP.png,
    DPPRO.png, DPXR.png, DPXRn.png, NoneFound.png).

    Layout
    ------
    Toolbar  : Robot combo (left) | System status label (right)      h=34
    -----------------------------------------------------------------------
    Sidebar  | Main panel
    w=160    | w=832
             |
    Image    | Drives group box  (rows created dynamically per drive count)
    91x91    |
             | Jobs label + ListView (15 visible rows, scrolls for more)
    Sys info |   oldest job at top, auto-scrolls to newest on refresh
             |
    Bins     |
             |
    Ink      |
    (dynamic)|
    -----------------------------------------------------------------------
    Footer   : Refresh | Check Bins | Align Printer | Abort Selected Job

    Changes from original
    ---------------------
    - Window height reduced to fit content tightly.
    - Robot Pic control capped at 91x91 (was 280x280).
    - Robot info, Bins, and Cartridges moved into a left sidebar (w=160).
    - Cartridge controls created dynamically; empty slots never shown.
    - Drive controls created dynamically (same pattern as cartridges);
      group box sized exactly to content — no hidden rows, no placeholder rows.
      Progress bar sits immediately after the drive text label.
      Window height adjusts automatically via WinMove when drive count changes.
    - System status on toolbar row, right-aligned.
      Green = OK; red = real error only ("No Error"/"No Errors" = green).
    - Jobs ListView shows 15 rows; scrolls when more jobs present;
      auto-scrolls to newest (last) item on each refresh.
      WM_SETREDRAW used during rebuild to eliminate flicker.
    - Selection reset on each refresh (by design).
#ce

#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <StaticConstants.au3>
#include <SendMessage.au3>
#include <WinAPI.au3>
#include <GDIPlus.au3>
#include <ComboConstants.au3>
#include <ListViewConstants.au3>
#include <ProgressConstants.au3>
#include <GuiListView.au3>
#include <GuiComboBox.au3>
#include <FontConstants.au3>
#include "PTBurnSDK.au3"

; Tell Windows this process is DPI-aware so pixel positions are not virtualized
; on 125%/150%/200% scaled displays.  Must be called before the first GUICreate.
; Without this, Windows DWM scales the window up by the DPI factor and all the
; pixel arithmetic (control positions, WinMove dimensions) would be doubled or
; tripled, breaking the layout.
#AutoIt3Wrapper_Res_HiDPI=y

Opt("GUIOnEventMode", 0)
Opt("MustDeclareVars", 1)

; ===========================================================================
; DEPLOYMENT CONFIGURATION
; ===========================================================================
; PTBurnService ships in two builds: MBCS (1-byte/ANSI) and Unicode (2-byte).
; This setting MUST match whichever build is installed on the server.
;
;   PTBURN_UNICODE = False   --> MBCS/ANSI build  (current installation)
;   PTBURN_UNICODE = True    --> Unicode build
;
; To check which build you have: look in the PTBurn install folder.
; The MBCS build is under ...\MBCS\  and the Unicode build under ...\UNICODE\.
; If you switch builds, change this value and reinstall PTBurnService.
;
; Background: PTBurnHistory.txt states that .JRQ, .PTM, and .INI files MUST
; use Unicode encoding when running the Unicode build.  The sample client
; (SampleClient.exe.config) exposes this as a user setting called
; "UnicodeEncoding" with a default of True — meaning it assumed Unicode.
; We default to False because this installation uses the MBCS build.
;
; What this flag controls in PTBurnSDK.au3:
;   Write: _PTBurn_OpenPtm() opens .ptm command files as UTF-16 LE (mode 32)
;   Read:  _PTBurn_AddJobFromFile() opens job files (.JRQ/.QRJ/.INP/.DON/.ERR)
;          as UTF-16 LE (mode 32).  Status .txt files are read via IniRead which
;          handles the UTF-16 LE BOM automatically — no flag needed for those.
; ===========================================================================
Global Const $PTBURN_UNICODE = False

Global Const $APP_VERSION    = "1.0.0"   ; increment on each release

Global Const $REFRESH_MS      = 2000    ; data polling interval (ms)
Global Const $HEALTH_CHECK_MS = 10000   ; share + service health check interval (ms)
                                        ; WMI query is synchronous but involves a COM
                                        ; round-trip — 10 s is frequent enough to catch
                                        ; outages without per-cycle overhead.

; ---------------------------------------------------------------------------
; Layout constants
; ---------------------------------------------------------------------------
Global Const $WIN_W        = 1000
Global Const $TB_H         = 50    ; toolbar height — tall enough for status to wrap to 2 lines
Global Const $SB_X         = 0
Global Const $SB_W         = 160   ; sidebar width
Global Const $SB_PAD       = 8
Global Const $MAIN_X       = $SB_W + 8
Global Const $MAIN_W       = $WIN_W - $MAIN_X - 4
Global Const $BODY_Y       = $TB_H + 4
Global Const $FTR_H        = 40

; Drive rows — created dynamically, no pre-allocation
Global Const $DRV_ROW_H    = 24    ; height per drive row
Global Const $DRV_GRP_HDR  = 18    ; group-box header
Global Const $DRV_GRP_BPAD = 8     ; bottom pad inside group
Global Const $DRV_INNER_X  = $MAIN_X + 8
; Label width — widened to accommodate drive description + state + disc number
Global Const $DRV_LBL_W    = 560
Global Const $DRV_PB_GAP   = 8
Global Const $DRV_PB_W     = 160

; Jobs list — exactly 15 visible rows
Global Const $JOBS_LV_H    = 292   ; 20hdr + 15*18rows + 2border

; Window height and footer Y are computed dynamically in _ResizeWindow() because
; they depend on the robot's drive count.  Initial values assume 2 drives (the most
; common configuration) so the window opens at a sensible size before the first
; data refresh.  _RebuildDriveCtrls() calls _ResizeWindow() whenever drive count
; changes, which updates these globals and resizes the window in place.
;
; Formula (derived from 2-drive baseline, verified against all drive counts 1-8):
;   drv_grp_h = DRV_GRP_HDR + n_drives * DRV_ROW_H + DRV_GRP_BPAD
;   jobs_lv_y = BODY_Y + drv_grp_h + 6 + 20       (gap 6 + "Jobs" label 20)
;   ftr_y     = jobs_lv_y + JOBS_LV_H + 28         (28 = LV-to-footer spacing)
;   win_h     = ftr_y + FTR_H + 4                  (4 absorbs title bar / chrome)
Global $WIN_H = 518   ; updated by _ResizeWindow() on drive count change
Global $FTR_Y = 474   ; updated by _ResizeWindow() on drive count change

; ---------------------------------------------------------------------------
; Controls
; ---------------------------------------------------------------------------
Global $g_hGUI
Global $g_cboRobot
Global $g_lblStatus
Global $g_lblServiceHealth
Global $g_picRobot
Global $g_lblRobotInfo
Global $g_lblBinL, $g_lblBinR, $g_lblBinLabelR
Global $g_lblSBDivider   ; sidebar vertical divider — height updated by _ResizeWindow()
Global $g_lvJobs
Global $g_btnRefresh, $g_btnCheckBins, $g_btnAlign, $g_btnAbort, $g_btnIgnoreInk

; GDI+ is owned by the GUI (started in _Main, shut down on exit)
Global $g_bGdipStarted = False

; Single-instance mutex handle — held for the lifetime of the process.
; Never closed explicitly; the OS releases it on process exit.
Global $g_hMutex = 0

; Global COM error handler — installed in _Main before any COM call.
; Without this, an unhandled COM exception (e.g. transient WMI failure) would
; fatally terminate the script.  The handler is a no-op: it just swallows the
; error and lets the calling code check IsObj() / @error and recover.
Global $g_oComError = 0

; Connectivity state — updated by _CheckServiceAlive() each health check cycle.
; $g_bServiceDead : PTBurnService Win32_Service.State is not "Running".
; $g_bShareDead   : \\server\PTBurnJobs share is not reachable (stronger check —
;                   catches network outages even when the service state cannot be queried).
; Command buttons are disabled whenever either flag is True.
Global $g_bServiceDead = False
Global $g_bShareDead   = False

; ---------------------------------------------------------------------------
; COM error handler — installed in _Main.  Called by AutoIt's COM dispatcher
; whenever an unhandled COM exception occurs.  We swallow the error so the
; script keeps running; callers must check IsObj() / @error on COM calls.
; ---------------------------------------------------------------------------
Func _PT_ComErrorHandler($oError)
    ; Intentionally empty — error is recorded in @error / @extended by AutoIt.
    ; Without a handler installed, unhandled COM errors are fatal.
    #forceref $oError
EndFunc

; ---------------------------------------------------------------------------
; Loads a PNG as an HBITMAP for STM_SETIMAGE on the robot Pic control.
; The image is rendered at its native pixel size, centered on a canvas of
; $iCanvasW x $iCanvasH (matching the Pic control dimensions).
; Win32 Static controls do not center or clip STM_SETIMAGE bitmaps — they
; stamp the bitmap from the top-left, so we do the centering here.
; Caller must _WinAPI_DeleteObject the returned handle when done with it.
; ---------------------------------------------------------------------------
Func _LoadPngAsHBITMAP($sPng, $iCanvasW, $iCanvasH)
    If $sPng = "" Or Not FileExists($sPng) Then Return 0
    Local $hImage = _GDIPlus_ImageLoadFromFile($sPng)
    If @error Or $hImage = 0 Then Return 0

    Local $iSrcW = _GDIPlus_ImageGetWidth($hImage)
    Local $iSrcH = _GDIPlus_ImageGetHeight($hImage)

    ; Center the image on the canvas — no scaling
    Local $iOffX = Int(($iCanvasW - $iSrcW) / 2)
    Local $iOffY = Int(($iCanvasH - $iSrcH) / 2)

    Local $hTarget   = _GDIPlus_BitmapCreateFromScan0($iCanvasW, $iCanvasH)
    If @error Or $hTarget = 0 Then
        _GDIPlus_ImageDispose($hImage)
        Return 0
    EndIf
    Local $hGraphics = _GDIPlus_ImageGetGraphicsContext($hTarget)
    _GDIPlus_GraphicsDrawImageRect($hGraphics, $hImage, $iOffX, $iOffY, $iSrcW, $iSrcH)
    _GDIPlus_GraphicsDispose($hGraphics)
    Local $hBmp = _GDIPlus_BitmapCreateHBITMAPFromBitmap($hTarget)
    _GDIPlus_BitmapDispose($hTarget)
    _GDIPlus_ImageDispose($hImage)
    Return $hBmp
EndFunc

; Cartridge controls — dynamic, up to 4
Global $g_aCartCtrls[4][2]
Global $g_iCartCount = 0

; Drive controls — dynamic, sized to $PTBURN_MAX_DRIVES pre-allocated slots.
; The actual drive count is determined at runtime by _PTBurn_GetDrives() which
; uses an unbounded loop (no hard cap).  $PTBURN_MAX_DRIVES is just the
; pre-allocation size of this array; if a robot ever has more drives, raise
; that constant in PTBurnSDK.au3 and this array will follow automatically.
; Each entry: [0]=label ctrl id, [1]=progressbar ctrl id, [2]=pct label ctrl id
Global $g_aDriveCtrls[$PTBURN_MAX_DRIVES][3]
Global $g_iDriveCtrlCount = 0
; Control ID of the Drives group box (recreated when drive count changes)
Global $g_idDrvGroup = 0
; Control ID of the zero-size "closing" group placeholder.  Recreated by
; _RebuildDriveCtrls and deleted by _DestroyDriveCtrls to avoid leaking IDs.
Global $g_idDrvGroupCloser = 0

Global $g_aRobots
Global $g_iRobotCount    = 0
Global $g_aJobItemIDs[0]
Global $g_aJobStems[0]   ; parallel array: filename stem for each job row (used by abort)
Global $g_aJobStates[0]  ; parallel array: PTBURN_JOB_* state for each row (gates abort)
Global $g_iLastShownType = -999
Global $g_hLastBitmap    = 0
Global $g_iLastTick      = 0
Global $g_iHealthTick    = 0   ; separate timer for the slower health check cycle
Global $g_iCartBaseY     = 0

; Y coordinate where Jobs label starts (set in _BuildGUI, updated in _RebuildDriveCtrls)
Global $g_lblJobs         = 0   ; "Jobs" section label (repositioned when drive count changes)
Global $g_iJobsLblY      = 0
Global $g_iJobsLvY       = 0

; =============================================================================
_Main()
; =============================================================================

Func _Main()
    ; ---- Single-instance guard -------------------------------------------
    ; CreateMutexW returns a handle whether or not the mutex already existed.
    ; GetLastError() = 183 (ERROR_ALREADY_EXISTS) means another instance owns it.
    ; We keep the handle in a global so it is never accidentally closed before
    ; the process exits (closing it would release the mutex and allow a second
    ; instance to start during the brief window before the process exits).
    $g_hMutex = DllCall("kernel32.dll", "handle", "CreateMutexW", _
            "ptr", 0, "bool", True, "wstr", "PTBurnStatusGUI_SingleInstance")
    If @error Or _WinAPI_GetLastError() = 183 Then
        MsgBox(48, "Already Running", "PTBurn Status Monitor is already running.")
        Exit
    EndIf
    ; ----------------------------------------------------------------------

    _PTBurn_Init(@ComputerName, $PTBURN_UNICODE)
    ; Install global COM error handler before any WMI / COM call.
    $g_oComError = ObjEvent("AutoIt.Error", "_PT_ComErrorHandler")
    _GDIPlus_Startup()
    $g_bGdipStarted = True
    _BuildGUI()
    GUISetState(@SW_SHOW, $g_hGUI)
    ; Run the health check before the first robot list refresh so command buttons
    ; start in the correct enabled/disabled state even if the share is unreachable
    ; at launch time.
    _CheckServiceAlive()
    _RefreshRobotList()
    $g_iLastTick   = TimerInit()
    $g_iHealthTick = TimerInit()

    Local $iMsg
    While 1
        $iMsg = GUIGetMsg()
        Switch $iMsg
            Case $GUI_EVENT_CLOSE
                ExitLoop
            Case $g_cboRobot
                _UpdateAll()
            Case $g_btnRefresh
                _RefreshRobotList()
            Case $g_btnCheckBins
                _CmdCheckBins()
            Case $g_btnAlign
                _CmdAlignPrinter()
            Case $g_btnAbort
                _CmdAbortJob()
            Case $g_btnIgnoreInk
                _CmdIgnoreInkLow()
        EndSwitch

        ; Data refresh — runs every REFRESH_MS (2 s)
        If TimerDiff($g_iLastTick) >= $REFRESH_MS Then
            _UpdateAll()
            $g_iLastTick = TimerInit()
        EndIf

        ; Health check — runs every HEALTH_CHECK_MS (10 s).
        ; Kept on a slower cadence because the WMI COM round-trip in
        ; _CheckServiceAlive() has more overhead than the data refresh.
        ; Also re-runs _RefreshRobotList so hot-plugged robots appear in the
        ; combo without requiring the user to click Refresh.
        If TimerDiff($g_iHealthTick) >= $HEALTH_CHECK_MS Then
            _CheckServiceAlive()
            _RefreshRobotList()
            $g_iHealthTick = TimerInit()
        EndIf

        Sleep(20)
    WEnd

    _PTBurn_Shutdown()
    If $g_hLastBitmap Then _WinAPI_DeleteObject($g_hLastBitmap)
    If $g_bGdipStarted Then _GDIPlus_Shutdown()
    GUIDelete($g_hGUI)
EndFunc

; =============================================================================
; GUI BUILD
; =============================================================================
Func _BuildGUI()
    $g_hGUI = GUICreate("PTBurn Disc Status Monitor v" & $APP_VERSION, $WIN_W, $WIN_H)

    ; ------------------------------------------------------------------
    ; Toolbar — Robot combo + service health on row 1.
    ; Status label spans the full toolbar height on the right so that
    ; long SDK error strings (Appendix C, up to ~180 chars) can wrap
    ; to a second line rather than being truncated.
    ; ------------------------------------------------------------------
    Local $iTB_Y = 7
    GUICtrlCreateLabel("Robot:", 8, $iTB_Y + 2, 46, 20)
    GUICtrlSetFont(-1, 9, $FW_BOLD)
    $g_cboRobot = GUICtrlCreateCombo("", 58, $iTB_Y, 200, 22, _
            BitOR($CBS_DROPDOWNLIST, $WS_VSCROLL))
    ; Service health indicator — sits right of the combo on the first row
    $g_lblServiceHealth = GUICtrlCreateLabel("", 266, $iTB_Y + 2, 160, 16, _
            BitOR($SS_LEFT, $SS_NOPREFIX))
    GUICtrlSetFont(-1, 9)
    ; Status label — full toolbar height so text can wrap to a second line.
    ; $WS_BORDER draws a plain box around the field so "System OK" and error
    ; strings don't float loose against the toolbar background.
    ; Inset by 4px on x and shrink width to match so the border has clear space.
    Local $iStatusX = 266 + 160 + 8
    $g_lblStatus = GUICtrlCreateLabel("", $iStatusX + 4, 6, $WIN_W - $iStatusX - 12, $TB_H - 8, _
            BitOR($SS_LEFT, $SS_NOPREFIX, $WS_BORDER))
    GUICtrlSetFont(-1, 9)
    GUICtrlCreateLabel("", 0, $TB_H, $WIN_W, 1, $SS_ETCHEDHORZ)

    ; ------------------------------------------------------------------
    ; Sidebar
    ; ------------------------------------------------------------------
    Local $iSY = $BODY_Y + $SB_PAD

    Local $iPicX = $SB_X + ($SB_W - 91) / 2
    $g_picRobot = GUICtrlCreatePic("", $iPicX, $iSY, 91, 91)
    GUICtrlSetState(-1, $GUI_DISABLE)
    $iSY += 95

    $g_lblRobotInfo = GUICtrlCreateLabel("", $SB_X + $SB_PAD, $iSY, $SB_W - $SB_PAD * 2, 56)
    GUICtrlSetFont(-1, 8)
    $iSY += 60

    GUICtrlCreateLabel("", $SB_X + $SB_PAD, $iSY, $SB_W - $SB_PAD * 2, 1, $SS_ETCHEDHORZ)
    $iSY += 6

    GUICtrlCreateLabel("Bins", $SB_X + $SB_PAD, $iSY, $SB_W - $SB_PAD * 2, 14)
    GUICtrlSetFont(-1, 8, $FW_BOLD)
    $iSY += 16

    Local $iBinLblW = 44
    GUICtrlCreateLabel("Left:", $SB_X + $SB_PAD, $iSY + 2, $iBinLblW, 16)
    GUICtrlSetFont(-1, 8)
    $g_lblBinL = GUICtrlCreateLabel("--", $SB_X + $SB_PAD + $iBinLblW, $iSY, _
            $SB_W - $SB_PAD * 2 - $iBinLblW, 20)
    GUICtrlSetFont(-1, 10, $FW_BOLD)
    $iSY += 22

    $g_lblBinLabelR = GUICtrlCreateLabel("Right:", $SB_X + $SB_PAD, $iSY + 2, $iBinLblW, 16)
    GUICtrlSetFont(-1, 8)
    $g_lblBinR = GUICtrlCreateLabel("--", $SB_X + $SB_PAD + $iBinLblW, $iSY, _
            $SB_W - $SB_PAD * 2 - $iBinLblW, 20)
    GUICtrlSetFont(-1, 10, $FW_BOLD)
    $iSY += 26

    GUICtrlCreateLabel("", $SB_X + $SB_PAD, $iSY, $SB_W - $SB_PAD * 2, 1, $SS_ETCHEDHORZ)
    $iSY += 6

    GUICtrlCreateLabel("Ink", $SB_X + $SB_PAD, $iSY, $SB_W - $SB_PAD * 2, 14)
    GUICtrlSetFont(-1, 8, $FW_BOLD)
    $iSY += 16

    $g_iCartBaseY = $iSY

    ; Vertical divider sidebar | main — height tracked so _ResizeWindow() can
    ; stretch it when the window grows to accommodate extra drive rows.
    $g_lblSBDivider = GUICtrlCreateLabel("", $SB_W, $BODY_Y, 1, $FTR_Y - $BODY_Y, $SS_ETCHEDVERT)

    ; ------------------------------------------------------------------
    ; Jobs section — Jobs label and ListView are created once here at
    ; placeholder positions.  _RebuildDriveCtrls() calls _RepositionJobs()
    ; after building the drive group box to move them to the correct Y
    ; based on the actual drive count.  Two drives is the typical default.
    ; ------------------------------------------------------------------
    Local $iDefaultDrvH = $DRV_GRP_HDR + 2 * $DRV_ROW_H + $DRV_GRP_BPAD
    $g_iJobsLblY = $BODY_Y + $iDefaultDrvH + 6
    $g_iJobsLvY  = $g_iJobsLblY + 20

    $g_lblJobs = GUICtrlCreateLabel("Jobs", $MAIN_X, $g_iJobsLblY, 60, 18)
    GUICtrlSetFont(-1, 10, $FW_BOLD)

    $g_lvJobs = GUICtrlCreateListView( _
            "Job Name|State|Good|Bad|Remaining|Status", _
            $MAIN_X, $g_iJobsLvY, $MAIN_W, $JOBS_LV_H, _
            BitOR($LVS_REPORT, $LVS_SHOWSELALWAYS, $LVS_SINGLESEL), _
            BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
    _GUICtrlListView_SetColumnWidth($g_lvJobs, 0, 340)
    _GUICtrlListView_SetColumnWidth($g_lvJobs, 1, 90)
    _GUICtrlListView_SetColumnWidth($g_lvJobs, 2, 55)
    _GUICtrlListView_SetColumnWidth($g_lvJobs, 3, 55)
    _GUICtrlListView_SetColumnWidth($g_lvJobs, 4, 75)
    ; The last column fills the remaining width.  We subtract 4 for the ListView
    ; border and an additional 17 for the vertical scrollbar (GetSystemMetrics
    ; SM_CXVSCROLL = 17 at standard DPI) so that when the scrollbar is visible
    ; the total column width still fits within the control — preventing the
    ; horizontal scrollbar from appearing whenever any jobs are listed.
    _GUICtrlListView_SetColumnWidth($g_lvJobs, 5, $MAIN_W - 340 - 90 - 55 - 55 - 75 - 4 - 17)

    ; ------------------------------------------------------------------
    ; Footer
    ; ------------------------------------------------------------------
    $g_btnRefresh   = GUICtrlCreateButton("Refresh",            $MAIN_X,       $FTR_Y, 110, 30)
    $g_btnCheckBins = GUICtrlCreateButton("Check Bins",         $MAIN_X + 118, $FTR_Y, 110, 30)
    $g_btnAlign     = GUICtrlCreateButton("Align Printer",      $MAIN_X + 236, $FTR_Y, 110, 30)
    $g_btnAbort     = GUICtrlCreateButton("Abort Selected Job", $MAIN_X + 354, $FTR_Y, 150, 30)
    $g_btnIgnoreInk = GUICtrlCreateButton("Ignore Ink Low",     $MAIN_X + 512, $FTR_Y, 120, 30)
    ; Ink Low button starts hidden — only shown when SysErrorNumber is 5, 6, or 7
    GUICtrlSetState($g_btnIgnoreInk, $GUI_HIDE)
EndFunc

; =============================================================================
; ROBOT LIST
; =============================================================================
Func _RefreshRobotList()
    $g_aRobots = _PTBurn_GetRobots()
    $g_iRobotCount = UBound($g_aRobots)
    If @error Then $g_iRobotCount = 0

    If $g_iRobotCount = 0 Then
        ; No status files found at all — service may not have run yet or share
        ; is unreachable.  Clear the combo fully before setting the placeholder so
        ; repeated offline polls do not accumulate "<robot not detected>" entries
        ; (GUICtrlSetData with a leading "|" appends rather than replaces).
        _GUICtrlComboBox_ResetContent($g_cboRobot)
        GUICtrlSetData($g_cboRobot, "<robot not detected>")
        _GUICtrlComboBox_SetCurSel($g_cboRobot, 0)
        Return
    EndIf

    ; Check whether the robot list came from RobotList (hardware live) or the
    ; offline fallback scan.  The SDK populates both the same way — we detect
    ; offline mode by checking if RobotList is absent from SystemStatus.txt.
    ; Guard against an empty path in case _PTBurn_Init was never called: IniRead
    ; on an empty filename returns the default and would wrongly set $bOffline=True.
    Local $bOffline = False
    If $g_sPTBurn_SystemFile <> "" Then
        $bOffline = (IniRead($g_sPTBurn_SystemFile, "RobotList", "Robot0", "") = "")
    EndIf

    ; Remember the currently selected robot name before rebuilding the combo so
    ; we can restore the selection afterward.  Strip the " [offline]" suffix if
    ; present — the label is re-applied below when the combo is rebuilt, and we
    ; want a clean robot name for the comparison.
    Local $sPrevSel = GUICtrlRead($g_cboRobot)
    $sPrevSel = StringReplace($sPrevSel, " [offline]", "")

    ; Rebuild the combo from scratch on every call so the list stays in sync
    ; with the current robot set (handles robots being added/removed at runtime).
    _GUICtrlComboBox_ResetContent($g_cboRobot)
    For $i = 0 To $g_iRobotCount - 1
        Local $sLabel = $g_aRobots[$i][$PT_R_NAME]
        If $bOffline Then $sLabel &= " [offline]"
        _GUICtrlComboBox_AddString($g_cboRobot, $sLabel)
    Next

    ; Restore the previously selected robot if it still exists in the new list.
    ; Fall back to index 0 if the robot has disappeared (e.g. physically removed).
    Local $iRestore = 0
    If $sPrevSel <> "" And $sPrevSel <> "<robot not detected>" Then
        For $i = 0 To $g_iRobotCount - 1
            If $g_aRobots[$i][$PT_R_NAME] = $sPrevSel Then
                $iRestore = $i
                ExitLoop
            EndIf
        Next
    EndIf
    _GUICtrlComboBox_SetCurSel($g_cboRobot, $iRestore)
    _UpdateAll()
EndFunc

Func _CurrentRobotIndex()
    If $g_iRobotCount = 0 Then Return -1
    Local $sSel = GUICtrlRead($g_cboRobot)
    ; Strip " [offline]" suffix if present so the name matches $g_aRobots entries
    $sSel = StringReplace($sSel, " [offline]", "")
    For $i = 0 To $g_iRobotCount - 1
        If $g_aRobots[$i][$PT_R_NAME] = $sSel Then Return $i
    Next
    Return -1
EndFunc

Func _CurrentRobotRow()
    Local $idx = _CurrentRobotIndex()
    Local $aRow[$PT_R_FIELDS]
    If $idx < 0 Then Return SetError(1, 0, $aRow)
    For $c = 0 To $PT_R_FIELDS - 1
        $aRow[$c] = $g_aRobots[$idx][$c]
    Next
    Return $aRow
EndFunc

Func _ClearUI()
    ; Clear robot image — send STM_SETIMAGE with null to detach the HBITMAP from
    ; the control before deleting it, then free the GDI handle.  GUICtrlSetImage("")
    ; alone does not release an HBITMAP set via STM_SETIMAGE, causing a GDI leak.
    _SendMessage(GUICtrlGetHandle($g_picRobot), $PT_STM_SETIMAGE, $PT_IMAGE_BITMAP, 0)
    If $g_hLastBitmap Then
        _WinAPI_DeleteObject($g_hLastBitmap)
        $g_hLastBitmap = 0
    EndIf
    $g_iLastShownType = -1   ; force image reload on next robot selection
    GUICtrlSetData($g_lblRobotInfo, "")
    GUICtrlSetData($g_lblStatus, "")
    GUICtrlSetColor($g_lblStatus, 0x000000)
    GUICtrlSetData($g_lblBinL, "--")
    GUICtrlSetData($g_lblBinR, "--")
    _DestroyCartCtrls()
    _DestroyDriveCtrls()
    Local $id
    For $id In $g_aJobItemIDs
        If $id <> 0 Then GUICtrlDelete($id)
    Next
    Local $aEmpty[0]
    $g_aJobItemIDs = $aEmpty
    $g_aJobStems   = $aEmpty
    $g_aJobStates  = $aEmpty
    GUICtrlSetState($g_btnIgnoreInk, $GUI_HIDE)
EndFunc

; -----------------------------------------------------------------------------
; Connectivity health check — called on a slow cadence (HEALTH_CHECK_MS).
;
; Two independent checks are made:
;
;   1. Share reachability (_PTBurn_ShareReachable): fastest check — detects any
;      condition where \\server\PTBurnJobs is inaccessible (power off, network
;      cable, share removed).  Runs first so we can skip the WMI query if the
;      network itself is down (WMI to a dead host can hang for several seconds).
;
;   2. Service state (WMI Win32_Service): detects the service being stopped
;      or crashed while the share is still mounted.  Queries Win32_Service
;      against the configured server via WMI.  Win32_Service.State is always
;      the English string "Running" regardless of Windows display language —
;      WMI property values are invariant, unlike sc.exe output which is
;      localized.  The call is synchronous and returns promptly on a reachable
;      host; the share check above guards against dead hosts.
;
; Command buttons (Check Bins, Align Printer, Ignore Ink Low) are disabled
; whenever either check fails — writing .ptm files to a dead share or a stopped
; service creates orphan commands that could fire unexpectedly on recovery.
; The Abort button is also disabled: an in-progress abort sent to a recovering
; service is unlikely to match a job that was running during the outage.
; The Refresh button is always enabled so the operator can manually re-poll.
; -----------------------------------------------------------------------------
Func _CheckServiceAlive()
    Local $bWasShareDead   = $g_bShareDead
    Local $bWasServiceDead = $g_bServiceDead

    ; ---- Check 1: share reachability ----------------------------------------
    $g_bShareDead = Not _PTBurn_ShareReachable()

    ; ---- Check 2: service state via WMI (only when share is up) ------------
    ; Win32_Service.State is always the English string "Running" regardless of
    ; the Windows display language — WMI property values are invariant, unlike
    ; sc.exe console output which is localized.
    ;
    ; A global COM error handler (_PT_ComErrorHandler) is installed in _Main, so
    ; any COM exception here sets @error rather than terminating the script.
    ; After each COM call we check @error / IsObj and fall back to "service dead".
    ;
    ; Note: ObjGet to an unreachable host can still block for the RPC timeout
    ; (~30-60s) on the AutoIt thread, freezing the GUI.  The share-reachability
    ; check above filters most of these, but a host with SMB up and RPC blocked
    ; will hang.  Acceptable trade-off for the simplicity of in-process WMI.
    If $g_bShareDead Then
        ; If the share is gone the WMI call to the same host would also fail or
        ; hang.  Mark service dead too so button state is consistent.
        $g_bServiceDead = True
    Else
        Local $sWMIPath = "winmgmts:{impersonationLevel=impersonate}!\\" & _
                $g_sPTBurn_Server & "\root\cimv2"
        Local $oWMI = ObjGet($sWMIPath)
        If @error Or Not IsObj($oWMI) Then
            $g_bServiceDead = True
        Else
            Local $oServices = $oWMI.ExecQuery( _
                    "SELECT State FROM Win32_Service WHERE Name='PTBurnService'")
            If @error Or Not IsObj($oServices) Then
                $g_bServiceDead = True
            Else
                ; .Count and the For-In iteration can also raise COM errors;
                ; the global handler turns those into @error so we keep going.
                Local $iCount = $oServices.Count
                If @error Or $iCount = 0 Then
                    ; Service not found — not installed or wrong server name
                    $g_bServiceDead = True
                Else
                    $g_bServiceDead = True   ; assume dead until confirmed running
                    For $oSvc In $oServices
                        Local $sState = $oSvc.State
                        If Not @error And $sState = "Running" Then
                            $g_bServiceDead = False
                        EndIf
                    Next
                EndIf
            EndIf
        EndIf
    EndIf

    ; ---- Update health label ------------------------------------------------
    Local $bUnhealthy = $g_bShareDead Or $g_bServiceDead
    If $g_bShareDead Then
        GUICtrlSetData($g_lblServiceHealth, "(!) Share not reachable")
        GUICtrlSetColor($g_lblServiceHealth, 0xCC0000)
    ElseIf $g_bServiceDead Then
        GUICtrlSetData($g_lblServiceHealth, "(!) Service not responding")
        GUICtrlSetColor($g_lblServiceHealth, 0xCC0000)
    Else
        If $bWasShareDead Or $bWasServiceDead Then
            ; Just recovered — clear the warning label
            GUICtrlSetData($g_lblServiceHealth, "")
            GUICtrlSetColor($g_lblServiceHealth, 0x000000)
        EndIf
    EndIf

    ; ---- Enable / disable command buttons -----------------------------------
    ; Refresh is always enabled.  All write-to-share commands are disabled while
    ; the share or service is unavailable to prevent orphan .ptm files.
    Local $iCmdState
    If $bUnhealthy Then
        $iCmdState = $GUI_DISABLE
    Else
        $iCmdState = $GUI_ENABLE
    EndIf
    GUICtrlSetState($g_btnCheckBins, $iCmdState)
    GUICtrlSetState($g_btnAlign,     $iCmdState)
    GUICtrlSetState($g_btnAbort,     $iCmdState)
    ; Ignore Ink Low is also a write command — disable it too.
    ; Its visibility (show/hide based on error number) is managed by _UpdateInfo;
    ; here we only set the enabled/disabled state.
    GUICtrlSetState($g_btnIgnoreInk, $iCmdState)
EndFunc

; =============================================================================
; UPDATE
; =============================================================================
Func _UpdateAll()
    If _CurrentRobotIndex() < 0 Then
        ; Only clear the UI if we genuinely have no robot data at all (not just
        ; temporarily offline — offline mode populates $g_aRobots from the status
        ; file fallback scan and sets $g_iRobotCount > 0).  If the combo shows
        ; "<robot not detected>" it means $g_iRobotCount = 0 and there's nothing
        ; to display.  If $g_iRobotCount > 0 but index is still -1, the combo
        ; selection is stale — don't wipe the last known display.
        If $g_iRobotCount = 0 Then _ClearUI()
        Return
    EndIf
    Local $aRobot = _CurrentRobotRow()
    _UpdateImage($aRobot)
    _UpdateInfo($aRobot)
    _UpdateBins($aRobot)
    _UpdateCarts($aRobot)
    _UpdateDrives($aRobot)
    _UpdateJobs($aRobot)
EndFunc

Func _UpdateImage($aRobot)
    ; AutoIt's GUICtrlSetImage / GUICtrlCreatePic cannot load PNG files natively —
    ; they only support BMP/ICO/JPG via the Win32 Pic control's SS_BITMAP style.
    ; We work around this by using GDI+ to decode the PNG into an HBITMAP and then
    ; sending STM_SETIMAGE directly to the control's window handle.
    ;
    ; Cleanup strategy: load the new bitmap first, send it to the control, then
    ; free the previously tracked handle.  We do NOT rely on STM_SETIMAGE's return
    ; value for cleanup — if the control previously held a system-owned bitmap the
    ; returned handle would not be ours to free, which was the source of the
    ; edge-case double-free identified in the audit.
    Local $iType = $aRobot[$PT_R_TYPE]
    If $iType = $g_iLastShownType Then Return
    $g_iLastShownType = $iType

    Local $sPng = _PTBurn_GetRobotImage($aRobot)
    Local $hBmp = _LoadPngAsHBITMAP($sPng, 91, 91)

    ; Send the new bitmap to the control (detaches whatever was there before)
    _SendMessage(GUICtrlGetHandle($g_picRobot), $PT_STM_SETIMAGE, $PT_IMAGE_BITMAP, $hBmp)

    ; Now it is safe to free the handle we previously tracked
    If $g_hLastBitmap Then _WinAPI_DeleteObject($g_hLastBitmap)
    $g_hLastBitmap = $hBmp
EndFunc

Func _UpdateInfo($aRobot)
    Local $aInfo = _PTBurn_GetSystemInfo($aRobot)
    GUICtrlSetData($g_lblRobotInfo, _
            $aRobot[$PT_R_TYPENAME] & @CRLF & _
            "FW: " & $aInfo[$PT_S_FW] & @CRLF & _
            "S/N: " & $aInfo[$PT_S_SERIAL])

    Local $sErr = $aInfo[$PT_S_ERROR]
    ; The canonical "is this an error?" signal per PDF Appendix C and the C# SystemError
    ; enum is SysErrorNumber: 0 means no error, anything else is an error.  String-based
    ; checks against "No Errors"/"No Error" are fragile to firmware text variations.
    Local $iErrNum = $aInfo[$PT_S_ERRNUM]
    Local $bRealError = ($iErrNum <> 0)

    Local $sText = $aInfo[$PT_S_STATUS]
    If $bRealError Then $sText &= "  |  Error: " & $sErr
    GUICtrlSetData($g_lblStatus, " " & $sText)   ; leading space keeps text off the left border
    If $bRealError Then
        GUICtrlSetColor($g_lblStatus, 0xCC0000)
    Else
        GUICtrlSetColor($g_lblStatus, 0x007700)
    EndIf

    ; Show "Ignore Ink Low" button only when the error is an ink-low condition.
    ; PDF §4.5: valid for SysErrorNumber 5 (color low), 6 (black low), 7 (both low).
    If $iErrNum = 5 Or $iErrNum = 6 Or $iErrNum = 7 Then
        GUICtrlSetState($g_btnIgnoreInk, $GUI_SHOW)
    Else
        GUICtrlSetState($g_btnIgnoreInk, $GUI_HIDE)
    EndIf
EndFunc

Func _UpdateBins($aRobot)
    Local $aBins = _PTBurn_GetBins($aRobot)
    GUICtrlSetData($g_lblBinL, $aBins[$PT_B_LEFT])
    If $aBins[$PT_B_HASRIGHT] Then
        GUICtrlSetData($g_lblBinR, $aBins[$PT_B_RIGHT])
        GUICtrlSetState($g_lblBinR, $GUI_SHOW)
        GUICtrlSetState($g_lblBinLabelR, $GUI_SHOW)
    Else
        GUICtrlSetData($g_lblBinR, "")
        GUICtrlSetState($g_lblBinR, $GUI_HIDE)
        GUICtrlSetState($g_lblBinLabelR, $GUI_HIDE)
    EndIf
EndFunc

; ---------------------------------------------------------------------------
; Cartridge controls — dynamic
; ---------------------------------------------------------------------------
Func _DestroyCartCtrls()
    For $i = 0 To $g_iCartCount - 1
        If $g_aCartCtrls[$i][0] <> 0 Then GUICtrlDelete($g_aCartCtrls[$i][0])
        If $g_aCartCtrls[$i][1] <> 0 Then GUICtrlDelete($g_aCartCtrls[$i][1])
        $g_aCartCtrls[$i][0] = 0
        $g_aCartCtrls[$i][1] = 0
    Next
    $g_iCartCount = 0
EndFunc

Func _RebuildCartCtrls($aCarts)
    _DestroyCartCtrls()
    Local $n = UBound($aCarts)
    If $n > 4 Then $n = 4
    Local $iCW = $SB_W - $SB_PAD * 2
    Local $iY  = $g_iCartBaseY
    For $i = 0 To $n - 1
        Local $sName = $aCarts[$i][$PT_C_NAME]
        Local $iFill = Int($aCarts[$i][$PT_C_FILL])
        $g_aCartCtrls[$i][0] = GUICtrlCreateLabel($sName & " (" & $iFill & "%)", _
                $SB_X + $SB_PAD, $iY, $iCW, 14)
        GUICtrlSetFont(-1, 8)
        $iY += 16
        $g_aCartCtrls[$i][1] = GUICtrlCreateProgress($SB_X + $SB_PAD, $iY, $iCW, 14)
        GUICtrlSetData(-1, $iFill)
        If $iFill >= $PTBURN_CART_OK_PCT Then
            GUICtrlSetColor(-1, 0x00AA00)
        ElseIf $iFill >= $PTBURN_CART_WARN_PCT Then
            GUICtrlSetColor(-1, 0xBBAA00)
        Else
            GUICtrlSetColor(-1, 0xCC2200)
        EndIf
        $iY += 18
    Next
    $g_iCartCount = $n
EndFunc

Func _UpdateCarts($aRobot)
    Local $aCarts = _PTBurn_GetCartridges($aRobot)
    Local $n = UBound($aCarts)
    If $n <> $g_iCartCount Then
        _RebuildCartCtrls($aCarts)
        Return
    EndIf
    For $i = 0 To $n - 1
        Local $iFill = Int($aCarts[$i][$PT_C_FILL])
        GUICtrlSetData($g_aCartCtrls[$i][0], $aCarts[$i][$PT_C_NAME] & " (" & $iFill & "%)")
        GUICtrlSetData($g_aCartCtrls[$i][1], $iFill)
        ; Update the bar colour on every refresh so threshold crossings (e.g. OK→Warn)
        ; are reflected immediately rather than waiting for a full rebuild.
        If $iFill >= $PTBURN_CART_OK_PCT Then
            GUICtrlSetColor($g_aCartCtrls[$i][1], 0x00AA00)
        ElseIf $iFill >= $PTBURN_CART_WARN_PCT Then
            GUICtrlSetColor($g_aCartCtrls[$i][1], 0xBBAA00)
        Else
            GUICtrlSetColor($g_aCartCtrls[$i][1], 0xCC2200)
        EndIf
    Next
EndFunc

; ---------------------------------------------------------------------------
; Drive controls — fully dynamic, same pattern as cartridges.
; Group box is deleted and recreated whenever drive count changes.
; Progress bar sits immediately after the text label on each row.
; ---------------------------------------------------------------------------
Func _DestroyDriveCtrls()
    For $i = 0 To $g_iDriveCtrlCount - 1
        If $g_aDriveCtrls[$i][0] <> 0 Then GUICtrlDelete($g_aDriveCtrls[$i][0])
        If $g_aDriveCtrls[$i][1] <> 0 Then GUICtrlDelete($g_aDriveCtrls[$i][1])
        If $g_aDriveCtrls[$i][2] <> 0 Then GUICtrlDelete($g_aDriveCtrls[$i][2])
        $g_aDriveCtrls[$i][0] = 0
        $g_aDriveCtrls[$i][1] = 0
        $g_aDriveCtrls[$i][2] = 0
    Next
    If $g_idDrvGroup <> 0 Then
        GUICtrlDelete($g_idDrvGroup)
        $g_idDrvGroup = 0
    EndIf
    If $g_idDrvGroupCloser <> 0 Then
        GUICtrlDelete($g_idDrvGroupCloser)
        $g_idDrvGroupCloser = 0
    EndIf
    $g_iDriveCtrlCount = 0
EndFunc

; Returns True if the drive state represents active operation with a meaningful
; burn/verify percentage to display.  Idle drives show no percentage.
Func _DriveIsActive($iState)
    Switch $iState
        Case $PTBURN_DRV_RECORDING, $PTBURN_DRV_READING, $PTBURN_DRV_VERIFYING, _
             $PTBURN_DRV_DISC_LOADED, $PTBURN_DRV_VERIFY_FAILED, _
             $PTBURN_DRV_VERIFY_COMPLETE, _
             $PTBURN_DRV_RECORD_FAILED, $PTBURN_DRV_RECORD_COMPLETE
            Return True
        Case Else
            Return False
    EndSwitch
EndFunc

Func _RebuildDriveCtrls($aDrives)
    _DestroyDriveCtrls()
    Local $n = UBound($aDrives)
    If $n > $PTBURN_MAX_DRIVES Then $n = $PTBURN_MAX_DRIVES
    Local $iVisible = $n
    If $iVisible < 1 Then $iVisible = 1

    Local $iGrpH = $DRV_GRP_HDR + $iVisible * $DRV_ROW_H + $DRV_GRP_BPAD
    $g_idDrvGroup = GUICtrlCreateGroup("Drives", $MAIN_X, $BODY_Y, $MAIN_W, $iGrpH)

    Local $iDY = $BODY_Y + $DRV_GRP_HDR
    For $i = 0 To $n - 1
        Local $sDesc  = StringStripWS($aDrives[$i][$PT_D_DESC] & " " & _
                        $aDrives[$i][$PT_D_LOCATION], 3)
        Local $sState = "[" & $aDrives[$i][$PT_D_STATETEXT] & "]"
        Local $sJob   = ""
        If $aDrives[$i][$PT_D_JOB] <> "" Then
            $sJob = "  Disc " & $aDrives[$i][$PT_D_DISC]   ; job name omitted — shown in Jobs list
        EndIf
        Local $sLine = $sDesc & "  " & $sState & $sJob

        $g_aDriveCtrls[$i][0] = GUICtrlCreateLabel($sLine, _
                $DRV_INNER_X, $iDY + 3, $DRV_LBL_W, 18)
        GUICtrlSetFont(-1, 8)

        $g_aDriveCtrls[$i][1] = GUICtrlCreateProgress( _
                $DRV_INNER_X + $DRV_LBL_W + $DRV_PB_GAP, _
                $iDY + 4, $DRV_PB_W, 14)
        Local $iPct = $aDrives[$i][$PT_D_PERCENT]
        GUICtrlSetData($g_aDriveCtrls[$i][1], $iPct)

        ; Percentage label — sits immediately right of the progress bar,
        ; visible only when the drive is active.
        Local $iPctX = $DRV_INNER_X + $DRV_LBL_W + $DRV_PB_GAP + $DRV_PB_W + 4
        $g_aDriveCtrls[$i][2] = GUICtrlCreateLabel("", $iPctX, $iDY + 3, 38, 16)
        GUICtrlSetFont(-1, 8)
        If _DriveIsActive($aDrives[$i][$PT_D_STATE]) Then
            GUICtrlSetData($g_aDriveCtrls[$i][2], $iPct & "%")
        EndIf

        $iDY += $DRV_ROW_H
    Next
    ; Close the Drives group with the AutoIt zero-size off-screen idiom.
    ; Track the placeholder ID so _DestroyDriveCtrls can delete it on the next
    ; rebuild — otherwise every rebuild leaks a control ID (max 65535/window).
    $g_idDrvGroupCloser = GUICtrlCreateGroup("", -99, -99, 1, 1)

    $g_iDriveCtrlCount = $n
    _RepositionJobs($iGrpH)
EndFunc

; Moves the Jobs label and ListView to sit immediately below the Drives group
; box, then resizes the window and repositions the footer buttons to match.
; Called by _RebuildDriveCtrls whenever the drive count changes.
Func _RepositionJobs($iDriveGrpH)
    $g_iJobsLblY = $BODY_Y + $iDriveGrpH + 6
    $g_iJobsLvY  = $g_iJobsLblY + 20
    GUICtrlSetPos($g_lblJobs, $MAIN_X, $g_iJobsLblY, 60, 18)
    GUICtrlSetPos($g_lvJobs,  $MAIN_X, $g_iJobsLvY,  $MAIN_W, $JOBS_LV_H)
    _ResizeWindow()
EndFunc

; Recalculates $WIN_H and $FTR_Y from the current Jobs ListView position, then
; resizes the main window and moves the footer buttons to the new $FTR_Y.
; Also updates the sidebar vertical divider height so it always reaches the footer.
; This is called from _RepositionJobs() every time the drive count changes.
;
; WinGetPos is used to read the current screen position before resizing so the
; window stays where the user placed it.  WinMove's -1,-1 does NOT mean "keep
; current position" — it is a literal coordinate that snaps the window to the
; top-left corner of the screen.
Func _ResizeWindow()
    $FTR_Y = $g_iJobsLvY + $JOBS_LV_H + 28   ; 28 = LV-to-footer spacing (empirical)
    $WIN_H = $FTR_Y + $FTR_H + 4              ; 4  = title bar / chrome overhead

    ; Read the current window position so we can preserve it during resize.
    ; A minimized window returns [-32000, -32000, w, h] — feeding those back into
    ; WinMove leaves the window invisible after restore.  Snap to (100, 100) in
    ; that case so the window comes back somewhere reasonable.
    Local $aPos = WinGetPos($g_hGUI)
    Local $iX, $iY
    If IsArray($aPos) Then
        $iX = $aPos[0]
        $iY = $aPos[1]
    Else
        $iX = 100
        $iY = 100
    EndIf
    If $iX < -10000 Then $iX = 100
    If $iY < -10000 Then $iY = 100
    WinMove($g_hGUI, "", $iX, $iY, $WIN_W, $WIN_H)

    ; Stretch the sidebar vertical divider to reach the new footer position
    GUICtrlSetPos($g_lblSBDivider, $SB_W, $BODY_Y, 1, $FTR_Y - $BODY_Y)

    ; Reposition footer buttons to the new $FTR_Y
    GUICtrlSetPos($g_btnRefresh,   $MAIN_X,       $FTR_Y, 110, 30)
    GUICtrlSetPos($g_btnCheckBins, $MAIN_X + 118, $FTR_Y, 110, 30)
    GUICtrlSetPos($g_btnAlign,     $MAIN_X + 236, $FTR_Y, 110, 30)
    GUICtrlSetPos($g_btnAbort,     $MAIN_X + 354, $FTR_Y, 150, 30)
    GUICtrlSetPos($g_btnIgnoreInk, $MAIN_X + 512, $FTR_Y, 120, 30)
EndFunc

Func _UpdateDrives($aRobot)
    Local $aDrives = _PTBurn_GetDrives($aRobot)
    Local $n = UBound($aDrives)

    ; Rebuild only when drive count changes (avoids flicker on normal refresh)
    If $n <> $g_iDriveCtrlCount Then
        _RebuildDriveCtrls($aDrives)
        Return
    EndIf

    ; Apply the same cap as _RebuildDriveCtrls — defensive guard against an OOB
    ; access into $g_aDriveCtrls[$PTBURN_MAX_DRIVES] if count exceeds the array size.
    If $n > $PTBURN_MAX_DRIVES Then $n = $PTBURN_MAX_DRIVES

    ; In-place update
    For $i = 0 To $n - 1
        Local $sDesc  = StringStripWS($aDrives[$i][$PT_D_DESC] & " " & _
                        $aDrives[$i][$PT_D_LOCATION], 3)
        Local $sState = "[" & $aDrives[$i][$PT_D_STATETEXT] & "]"
        Local $sJob   = ""
        If $aDrives[$i][$PT_D_JOB] <> "" Then
            $sJob = "  Disc " & $aDrives[$i][$PT_D_DISC]   ; job name omitted — shown in Jobs list
        EndIf
        GUICtrlSetData($g_aDriveCtrls[$i][0], $sDesc & "  " & $sState & $sJob)
        Local $iPct = $aDrives[$i][$PT_D_PERCENT]
        GUICtrlSetData($g_aDriveCtrls[$i][1], $iPct)
        If _DriveIsActive($aDrives[$i][$PT_D_STATE]) Then
            GUICtrlSetData($g_aDriveCtrls[$i][2], $iPct & "%")
        Else
            GUICtrlSetData($g_aDriveCtrls[$i][2], "")
        EndIf
    Next
EndFunc

; ---------------------------------------------------------------------------
; Jobs — oldest first, auto-scroll to newest on each refresh.
; WM_SETREDRAW suppresses repainting during the delete/rebuild cycle so the
; control never appears blank mid-update, eliminating the visible flicker.
; RedrawWindow forces a clean repaint immediately after redraws are re-enabled.
; ---------------------------------------------------------------------------
Func _UpdateJobs($aRobot)
    Local $hLV = GUICtrlGetHandle($g_lvJobs)

    ; Suspend repainting for the duration of the update
    _SendMessage($hLV, $WM_SETREDRAW, False, 0)

    Local $aJobs = _PTBurn_GetJobs($aRobot)
    Local $id
    For $id In $g_aJobItemIDs
        If $id <> 0 Then GUICtrlDelete($id)
    Next
    Local $aEmpty[0]
    $g_aJobItemIDs = $aEmpty
    $g_aJobStems   = $aEmpty
    $g_aJobStates  = $aEmpty

    Local $iCount = UBound($aJobs)
    For $i = 0 To $iCount - 1
        Local $sLine = $aJobs[$i][$PT_J_NAME]      & "|" & _
                       $aJobs[$i][$PT_J_STATETEXT] & "|" & _
                       $aJobs[$i][$PT_J_GOOD]      & "|" & _
                       $aJobs[$i][$PT_J_BAD]       & "|" & _
                       $aJobs[$i][$PT_J_REMAINING] & "|" & _
                       $aJobs[$i][$PT_J_STATUS]
        Local $idItem = GUICtrlCreateListViewItem($sLine, $g_lvJobs)
        GUICtrlSetBkColor($idItem, _PTBurn_JobRowColor( _
                $aJobs[$i][$PT_J_STATE], $aJobs[$i][$PT_J_COMPLETED]))
        ReDim $g_aJobItemIDs[UBound($g_aJobItemIDs) + 1]
        $g_aJobItemIDs[UBound($g_aJobItemIDs) - 1] = $idItem
        ReDim $g_aJobStems[UBound($g_aJobStems) + 1]
        $g_aJobStems[UBound($g_aJobStems) - 1] = $aJobs[$i][$PT_J_STEM]
        ReDim $g_aJobStates[UBound($g_aJobStates) + 1]
        $g_aJobStates[UBound($g_aJobStates) - 1] = $aJobs[$i][$PT_J_STATE]
    Next

    ; Re-enable repainting and force an immediate repaint of the whole control
    _SendMessage($hLV, $WM_SETREDRAW, True, 0)
    _WinAPI_RedrawWindow($hLV, 0, 0, BitOR($RDW_INVALIDATE, $RDW_UPDATENOW))

    ; Scroll to top — jobs are now sorted newest-first by _PTBurn_ScanJobFolderTracked,
    ; so the most recent activity is at row 0 and should be visible after refresh.
    If $iCount > 0 Then _GUICtrlListView_EnsureVisible($g_lvJobs, 0, False)
EndFunc

; =============================================================================
; COMMANDS
; =============================================================================
Func _CmdCheckBins()
    If _CurrentRobotIndex() < 0 Then Return
    If Not _PTBurn_SendMessage(_CurrentRobotRow(), "CHECK_DISCSINBIN") Then
        MsgBox(48, "Check Bins", "Could not write command file." & @CRLF & _
               "Check that PTBurnService is running and the share is reachable.")
    EndIf
EndFunc

Func _CmdAlignPrinter()
    If _CurrentRobotIndex() < 0 Then Return
    If Not _PTBurn_SendMessage(_CurrentRobotRow(), "ALIGN_PRINTER") Then
        MsgBox(48, "Align Printer", "Could not write command file." & @CRLF & _
               "Check that PTBurnService is running and the share is reachable.")
    EndIf
EndFunc

Func _CmdAbortJob()
    If _CurrentRobotIndex() < 0 Then Return
    ; Use _GetSelectedCount rather than checking for an empty string from
    ; _GetSelectedIndices — historical AutoIt bug (ticket #606) returns "" when
    ; row 0 is the selection, which would mis-treat as "nothing selected".
    If _GUICtrlListView_GetSelectedCount($g_lvJobs) = 0 Then
        MsgBox(64, "Abort Job", "Select a job in the list first.")
        Return
    EndIf
    Local $sIdx = _GUICtrlListView_GetSelectedIndices($g_lvJobs, False)
    ; Use the filename stem stored in $g_aJobStems, not the display name in the ListView.
    ; The .ptm abort file must be named after the job filename stem, not the JobTitle.
    Local $iRow = Int($sIdx)
    If $iRow < 0 Or $iRow >= UBound($g_aJobStems) Then Return
    Local $sStem = $g_aJobStems[$iRow]
    If $sStem = "" Then Return
    ; Gate by job state — a .ptm abort on an already-finished job is a no-op
    ; orphan file that PTBurnService never consumes.
    If $iRow < UBound($g_aJobStates) Then
        Local $iState = $g_aJobStates[$iRow]
        If $iState = $PTBURN_JOB_COMPLETED Or _
           $iState = $PTBURN_JOB_FAILED    Or _
           $iState = $PTBURN_JOB_MOVED Then
            MsgBox(64, "Abort Job", "Job is already finished - nothing to abort.")
            Return
        EndIf
    EndIf
    Local $bOk = _PTBurn_AbortJob(_CurrentRobotRow(), $sStem)
    If Not $bOk Then
        Local $iErr = @error
        ; Error codes from _PTBurn_AbortJob:
        ;   1 = file open / write failed
        ;   2 = empty job name (filtered above, shouldn't reach here)
        ;   3 = .ptm already exists — abort already pending for this job
        ;   4 = name fully stripped by sanitization
        Switch $iErr
            Case 3
                MsgBox(64, "Abort Job", "An abort is already queued for this job.")
            Case 1
                MsgBox(48, "Abort Job", "Could not write abort file." & @CRLF & _
                       "Check that PTBurnService is running and the share is reachable.")
            Case Else
                MsgBox(48, "Abort Job", "Abort failed (error " & $iErr & ").")
        EndSwitch
    EndIf
EndFunc

Func _CmdIgnoreInkLow()
    ; Button is only visible when SysErrorNumber is 5, 6, or 7, so no extra
    ; guard needed here — but we confirm a robot is selected for safety.
    Local $aRobot = _CurrentRobotRow()
    If @error Then Return
    If Not _PTBurn_SendIgnoreInkLow($aRobot) Then
        MsgBox(48, "Ignore Ink Low", "Could not write command file." & @CRLF & _
               "Check that PTBurnService is running and the share is reachable.")
    EndIf
EndFunc
