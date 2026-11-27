# REPORT: Realtek SDK research for the blue "No Signal" screen

Research only. Nothing was run against the monitor (`rtd-isp`, `m1ddc` not used). `firmware/` not touched.
Sources read via `gh api` (raw contents, trees) and `gh search code`.

Repo prefixes used below: `RTD:` = Kingdomwhisky/RTD-Scaler-TEST (branch main), `MP:` = xiangjianhe/MonitorPro (branch master, 2017 copy of the same SDK), `DDC:` = awto-au/awto-ddc (branch main).

## Summary (10 lines)

1. No normal SDK path paints blue. Reset-to-search sets background BLACK and force-to-background ON: `RTD: Kernel/Scaler/ScalerFunction/Code/ScalerGlobal.c:206-207`. That matches the brief's black step.
2. Only two SDK call sites pass blue (0,0,255). (a) Factory QC no-signal routine, `RTD: User/None Series/NoneOsd/Code/NoneOsd.c:139`, compiled only if `_FACTORY_RTD_QC_SUPPORT == _ON` (default `_OFF` in the awto copy, `DDC: fw/sdk/Kernel/Common/QC_Option.h:22`). Its order is BL on, red, green, blue (500 ms each), BG off, BL off. That does not match the brief's order (BL off, then later BL on with blue).
3. (b) DDC/CI display-calibration blue step, `RTD: Kernel/User Common Function/Code/UserCommonDisplayCalibrationGen0.c:292`. Its exit resets to black (`:993-994`). If calibration stops before the exit, blue with force-to-BG could stay latched. This is the best candidate for "blue held with a blank no-signal state", but it needs DDC/CI calibration traffic to start it.
4. The background colour is a persistent register, not a reset default. Colour data port `P0_6D` (index port `P0_6C` bit5), force-to-BG `P0_28` bit5. The regdb reset for force-BG is 1 and colour reset is 0x00 (black), `DDC: re/regdb/RTD2795T-CG.tsv.gz`. A path that enables BG without writing a colour shows whatever colour was last written.
5. Backlight in the SDK: `UserCommonInterfacePanelPowerAction(_BACKLIGHT_ON)` is called on ACTIVE entry (`RTD: Kernel/System/Code/SysMode.c:303`) and in the panel-power state machine (`RTD: Kernel/User Common Function/Code/UserCommonInterface.c:761-890`), timed by `_PANEL_POWER_ON_T3` and `_USER_TIMER_EVENT_PANEL_BACKLIGHT_ON`. No SDK timer turns the backlight back on after NOSIGNAL.
6. Backlight pin: SDK demo `bBACKLIGHTPOWER` is `MCU_FE25` = P8.5, active low (`RTD: Pcb/RL6449/LQFP_216/RL6449_DEMO_E_1A1H1DP_DPTX_eDP.h:288-294`). awto-ddc proved P8.5 is NOT the enable on their board. Their enable is P9.2 = `FE2A`, active low, and PWM4 is P9.1 (`DDC: docs/history.md` 2026-11-06, `docs/monitors/gpio-roles.md`). Binary search: `90 FE 2A` (MOV DPTR,#FE2Ah) followed within ~10 bytes by `F0` (MOVX @DPTR,A). Control search: `90 FE 25`.
7. Blue, 10-bit path (the brief says the monitor is 10-bit): `ScalerDDomainBackgroundSetColor10bit(0,0,0x3FF)` writes the port bytes `00 00 FF 0C` (`RTD: Kernel/Scaler/RL6449_Series_Scaler/Code/RL6449_Series_DDomain.c:97-110`). The 8-bit path writes `00 00 FF 00` (`:76-89`).
8. No project option for a no-signal colour or a no-backlight delay exists in the SDK sources read (`RTD: Kernel/Common/Project_Option.h`, `Kernel/Common/RL6449_Pcb_Default.h`). Power saving on NOSIGNAL is immediate when QC is off (`NoneOsd.c:146-148`). awto-ddc has no doc on a no-signal or power-save colour.
9. Caveat on chip identity: the SDK in these repos is RL6449/RL6463 series. There is no RTD2795 kernel source in either repo. The awto-ddc RTD2795T regdb matches the register names and addresses (`0x28`, `0x6C`, `0x6D`), so the addresses are a usable lead, not proof for the UPERFECT M245T01.
10. Net: the most likely source is the factory-QC or calibration blue code left in the image and reached by a flow the brief has not named. Test first: does the blue come back after a DDC/CI calibration session, or after a cold boot with no source? Next binary searches: `90 FE 2A` / `90 FE 25` near backlight writes, and the `00 00 FF 0C` / `00 00 FF 00` byte groups near `MOV Rn,#6Dh` (`7x 6D`) writes.

---

## Q1. What runs in NOSIGNAL / NOSUPPORT / power saving; where could blue come from?

### State flow (SDK, RTD repo)
- `Kernel/System/Code/SysJudge.c:150` arms `_SYSTEM_TIMER_EVENT_JUDGE_NOSIGNAL_STATE` at SEC(1). `:173` calls `SysJudgeStateChangeEvent(_MODE_STATUS_NOSIGNAL)` once `GET_SOURCE_SWITCH_FINISH()`.
- `Kernel/System/Code/SysTimer.c:120-121`: when that timer fires, `SET_MODE_RESET_TARGET(_MODE_ACTION_RESET_TO_NOSIGNAL)`.
- `Kernel/System/Code/SysJudge.c:468-482` (`_MODE_ACTION_RESET_TO_NOSIGNAL`): cancels the timer, changes state to NOSIGNAL.
- `Kernel/System/Code/SysMode.c:132-133` (case NOSIGNAL / POWER_SAVING): if `UserInterfaceGetCableResetStatus()`, sets target power NORMAL and `_MODE_ACTION_RESET_TO_SEARCH` (`:126-135`). No backlight call in this case.
- `User/None Series/NoneOsd/Code/NoneOsd.c:127-151` (NOSUPPORT / NOSIGNAL OSD case). With QC off, the only action is `SysPowerSetTargetPowerStatus(_POWER_STATUS_SAVING)` (`:146-148`) when the mode state changes. No delay.
- `Kernel/System/Code/SysMode.c:583-609` (`_MODE_ACTION_RESET_TO_SEARCH`) calls `SysModeSetFreeRun()` (`:603`). `SysModeSetFreeRun` is at `:715-742`; line `:725` is `ScalerMDomainSetDisplayFormat(_FREE_RUN_NO_INPUT)`. No colour is set there.
- `Kernel/Scaler/ScalerFunction/Code/ScalerGlobal.c:206-207` (RESET_TO_SEARCH): `ScalerDDomainBackgroundSetColor(0,0,0)` then `ScalerDDomainBackgroundEnable(_ENABLE)`. Black, force-BG on.
- `Kernel/Scaler/ScalerFunction/Code/ScalerGlobal.c:261-262` (RESET_TO_DISPLAY_SETTING): same black + enable.
- `Kernel/Scaler/RL6449_Series_Scaler/Code/RL6449_Series_Global.c:411`: black on a reset path.
- `User/None Series/NoneFunction/Code/NoneUserInterface.c:2451`: `ScalerDDomainBackgroundEnable(_DISABLE)` when the translator is off.

### Every SDK call site of the colour setter (RTD repo)
| File:line | Colour | Reached when |
|---|---|---|
| `NoneOsd.c:132,135,137,139` | black, red, green, BLUE | `_FACTORY_RTD_QC_SUPPORT == _ON`, NOSUPPORT/NOSIGNAL state |
| `ScalerDDomain.c:145,152` | gray level / red | DDomain FreeSync OD calibration tool |
| `ScalerGlobal.c:206,261` | black | reset to search / display setting |
| `RL6449_Series_Global.c:411` | black | reset path |
| `UserCommonDisplayCalibrationGen0.c:271` | red | DDC/CI display-calibration step OGC_MEASURE_RED |
| `UserCommonDisplayCalibrationGen0.c:281` | black | calibration step MEASURE_BLACK |
| `UserCommonDisplayCalibrationGen0.c:292` | BLUE | calibration step MEASURE_BLUE |
| `UserCommonDisplayCalibrationGen0.c:304,312,323,344,355` | green / white / gray table | calibration steps |
| `UserCommonDisplayCalibrationGen0.c:994` | black | calibration END (with `ScalerDDomainBackgroundEnable(_DISABLE)` at `:993`) |
| `RTDFactoryFunction.c:3252,3258,3264` | user R/G/B | factory menu, DDC/CI-driven (RTD Factory) |

Checked: MP copy has the same QC blue at `MP: code/User/None Series/NoneOsd/Code/NoneOsd.c:145`. The MP copy calls `UserInterfacePanelPowerAction` (not `UserCommon...`), so it is an older revision of the same code.

### Ranked candidates for the blue screen
1. **Factory QC NOSIGNAL routine (`NoneOsd.c:129-151`).** It is the only SDK path whose NOSIGNAL state shows colours on its own, and its final colour is blue. Mismatches with the brief: (i) it turns the backlight ON first, not after a delay; (ii) it turns the backlight OFF at the end, not on; (iii) it takes about 1.5 s total. If the vendor build reorders these steps or skips the disable, the result would look like the brief. Needs `_FACTORY_RTD_QC_SUPPORT == _ON` in the image (default `_OFF` in the awto fw/sdk copy).
2. **Display-calibration blue (`UserCommonDisplayCalibrationGen0.c:292`).** It leaves force-BG on until the END step (`:993-994`). If a DDC/CI calibration session is interrupted (monitor reset, DDC timeout, host killed the session) the screen stays blue with BG on. Needs DDC/CI calibration commands to start it. Check: does the host (or any tool) send calibration VCP commands at the time of signal loss?
3. **Latched colour register.** Colour values persist until written (see Q2). Any path that enables force-BG without writing a colour shows the last colour. The brief's black step writes black, so this only matters if a blue write is not followed by a black write.
4. **Free-run / pattern generator / OSD window:** no SDK code sets blue in these paths (checked `SysMode.c:715-742`, `ScalerDDomain.c`, `NoneOsd.c`). Not verified in the image.

---

## Q2. Backlight switching: function, timing, pin

### Function and timing (SDK)
- `UserCommonInterfacePanelPowerAction` at `RTD: Kernel/User Common Function/Code/UserCommonInterface.c:761`.
- `_BACKLIGHT_ON` path: `ScalerTimerActiveTimerEvent(_PANEL_POWER_ON_T3, _USER_TIMER_EVENT_PANEL_BACKLIGHT_ON)` at `:842, :854, :874, :886` (one per panel type: LVDS, TTL, VBO, DPTX). Sets `_WAITING_FOR_BACKLIGHT`.
- Event handler: `User/None Series/NoneFunction/Code/NoneUserInterface.c:663-664`: `SET_PANELPOWERSTATUS(_READY_FOR_BACKLIGHT)`.
- Consumer: `UserCommonInterface.c:1278` `ScalerTimerWaitForActiveTimerEvent(_USER_TIMER_EVENT_PANEL_BACKLIGHT_ON)`, then the pin write.
- Cancel points: `UserCommonInterface.c:1058, :1428`.
- Backlight-on call in the mode machine: `SysMode.c:303` (ACTIVE entry). Backlight-off calls: `SysMode.c:277-278` (display setting, `_PANEL_OFF`), `:455` (display init), `:738` (free-run set).
- The SDK has no timer that turns the backlight back on after NOSIGNAL. `SysPower.c` has no backlight or panel call (grep empty).

### Pin macros
- Common default: `RTD: Kernel/Common/RL6449_Pcb_Default.h:1208-1216`: `PCB_BACKLIGHT_POWER_PIN(x)` / `PCB_BACKLIGHT_POWER(x)` are empty unless the board header defines them.
- Demo board (LQFP_216): `RTD: Pcb/RL6449/LQFP_216/RL6449_DEMO_E_1A1H1DP_DPTX_eDP.h:288-308`: `bBACKLIGHTPOWER = MCU_FE25_PORT85_PIN_REG` (P8.5, pin 185), `_LIGHT_CONTROL_ON 0`, `_LIGHT_CONTROL_OFF 1`. PWM for backlight is `_PWM2`, inverse (`:134-135`).
- QA board (LQFP_156): `RTD: Pcb/RL6449/LQFP_156/RL6449_QA_A_156PIN_2H1DP_eDP.h:289-299`: same `MCU_FE25` name, comment says "pin 138".
- Naming convention (inferred from the header names, not checked against a datasheet): XDATA address = `0xFE20 + (port - 8) * 8 + pin` for port 8/9. Checks: P8.1 = FE21, P8.4 = FE24, P8.5 = FE25, P9.0 = FE28, P9.2 = FE2A, all match the names in these headers and in awto-ddc.
- Awto's board: P9.2 (`FE2A`) active low is the enable, proven live 2026-11-06 (`DDC: docs/history.md`, `DDC: docs/monitors/gpio-roles.md` row 196). P9.1 is PWM4 (`FE29` by the formula).
- Binary search: `90 FE 2A` (MOV DPTR,#FE2Ah), then `F0` (MOVX @DPTR,A) within ~10 bytes; writes of `00` and `01` next to it are the on/off pair (0 = on, 1 = off, active low). Caveat: the SDK demo pin is P8.5. Do not assume the monitor uses P8.5.

---

## Q3. Project options: no-signal colour, no-backlight, power-saving delays

- Searched `RTD: Kernel/Common/Project_Option.h` (387 lines) and `RL6449_Pcb_Default.h`: no option for no-signal colour, no backlight-off-on-no-signal, no no-signal delay. Only `_BACKLIGHT_DIMMING_SUPPORT`, power-saving ref clock (`:361`), Eizo cache (`:366`).
- `RTD: Project/Header/Project_User_Beacon_Default.h:89`: `Dynamic_Show_NoSignal_NoSupport` (OFF). This is an OSD card option, not a colour or power option.
- `DDC: fw/sdk/Kernel/Common/QC_Option.h:22`: `_FACTORY_RTD_QC_SUPPORT _OFF`. This is the only switch that enables the blue NOSIGNAL sequence. Its value in the monitor image is unknown.
- Power-saving delays: only in awto's own firmware (`DDC: docs/power-levels.md`, L1/L2/L3 timers). Not in the SDK.
- Not checked: the `_PANEL_POWER_ON_T1..T6` definitions (used at `UserCommonInterface.c`, defined in a project/PCB header not fetched).

---

## Q4. awto-ddc notes on no-signal / power-save colour or pattern

- Searched the repo for "no signal", "NO SIGNAL", "power-save", "Power-save pattern", "blue", "0000FF". No doc describes a no-signal or power-save background colour or pattern. Hits are OSD cards and tests (`docs/osd-screens-as-data.md:19`, `docs/input-status.md:8`, `docs/osd.md:62, :151`).
- `DDC: docs/history.md` has no entry on no-signal colour.
- What awto found and changed that is relevant:
  - `DDC: docs/history.md`, 2026-11-06: backlight enable is P9.2 active low, not P8.5 (SDK name `bBACKLIGHTPOWER`). P8.5 only follows it.
  - `DDC: docs/monitors/gpio-roles.md`: P9.2 = backlight enable (active low, proven). P8.4/P8.5/P9.7/PA.0 = NORMAL-state enables, not LED. P3.5/P3.6 = power LED.
  - `DDC: docs/power-levels.md`: signal lost in ACTIVE -> hold with backlight off (L1); after `pwr_l2_s` (60 s default) the SDK no-signal path runs (L2); L3 off = ignore saving requests. Own firmware design; no blue.
  - `DDC: docs/design-162.md:69`: "Hidden blink": `_BACKLIGHT_ON` contained a `#if(_USER_PROJECT_TYPE == ...)` branch that was always taken with both sides undefined, so every backlight-on call toggled the pin (pin off, 10 ms, on). They fixed it in their own panel machine. Relevant if the monitor's SDK still has this code: a backlight blink can look like a "turn on after a few seconds" event.
- `DDC: re/lib-review/realtek-sdk-bugs.md`: two SDK bugs (FRC DHF byte overwrite; DPLL 16-bit overflow). Neither affects colour or backlight.

---

## Byte patterns and constants for the Keil 8051 binary

- Register map (RTD2795T regdb, `DDC: re/regdb/RTD2795T-CG.tsv.gz`):
  - `0x0028` VIDEO_DISPLAY_CONTROL_REG: reset `0x20`. bit5 `force_bg_en`, reset 1. Force-to-BG on by default at power-up.
  - `0x006C` OVERLAY_CTRL: bit5 `bg_color_access_en` (index port). The SDK writes 0 then 1, sets the data, then 0 again.
  - `0x006D` BG_COLOR_DATA_PORT_M1: writes R, G, B, then a fourth byte (8-bit path: `00`; 10-bit path: low 2 bits of R/G/B packed as `(R&3)<<6 | (G&3)<<4 | (B&3)<<2`).
  - `0x000C` WATCH_DOG_CTRL0 bit1 `m1_bg_en` (watchdog action = background), reset 0x00.
- Same addresses in the RL6463 header (`RTD: Kernel/Scaler/RL6463_Series_Scaler/Header/RL6463_Series_RegCommonInclude.h:1368, :1425, :1526-1527`). RL6449 header not located in the repo (fetch returned 404 for the guessed path).
- Blue, 8-bit: data bytes `00 00 FF 00` written to `0x6D` after the `0x6C` bit5 toggle (`RL6449_Series_DDomain.c:76-89`).
- Blue, 10-bit: data bytes `00 00 FF 0C` (`RL6449_Series_DDomain.c:97-110`, with `usBlue = 0x3FF`).
- Search in the Keil image: the scaler register accesses go through the SDK's `ScalerSetByte`/`ScalerSetBit` helpers, so the register number is an argument, not an inline immediate. Look for `MOV Rn,#6Dh` (`7x 6D`) or `MOV Rn,#6Ch` (`7x 6C`) and `MOV Rn,#28h` (`7x 28`) near the colour writes, then the `FF` / `0C` data bytes. This is weak (many false hits); use it as a locator, not a proof.
- Backlight XDATA: `90 FE 2A` (P9.2 enable, awto-proven), `90 FE 25` (P8.5, SDK demo name only), `90 FE 29` (P9.1 PWM4, by formula).

---

## Discrepancies and caveats

- **Chip identity.** The brief calls awto-ddc an "RTD2795 firmware". The repo's firmware is an RL6449 build (`fw/sdk/`), with an RTD2795T regdb for the JXC 4K board. The RTD repo has no RTD2795 scaler kernel; its scaler folders are RL6369/6410/6432/6449/6463/6492 only (`RTD: Kernel/Scaler/`). The UPERFECT M245T01 chip is not identified in any repo read. Treat the SDK behaviour as a model, not proof.
- **Order mismatch.** The QC NOSIGNAL routine (`NoneOsd.c:129-151`) and the brief's observed order (BL off, later BL on + blue) do not match. Either the image differs from the SDK, or blue comes from another path.
- **Latched colour.** Colour and force-BG registers survive an MCU-only reset (awto notes a warm boot clears OSD SRAM, `DDC: power-levels.md`). Whether the scaler registers survive a monitor power cycle is not checked here. Test on hardware before relying on it.
- **Not searched in full.** `gh search code` hit limits once (`HTTP 403`), so some queries were not repeated. Not read: `RTDFactoryFunction.c` full body beyond the colour lines, `UserCommonDisplayCalibrationGen0.c` beyond lines 255-300 and 980-996, the awto `re/` Ghidra notes for colour strings.
- **No binary was read.** Nothing here is checked against the monitor's firmware binary. All byte patterns are untested.

## Suggested next steps (no monitor contact needed)
1. In the image, find the backlight writes: `90 FE 2A` and `90 FE 25` followed by `F0`. Note the on/off value pair.
2. Find `MOV Rn,#6Dh` (`7x 6D`) sites, then look for a 4-byte write group `00 00 FF xx`. The group with `FF` in the blue slot and a `6C` bit5 toggle either side is the blue writer.
3. Count the blue writers. If there is one, in a NOSIGNAL-reachable function, that is the mechanism. If there are two (QC and calibration), check whether the QC block is compiled in (`_FACTORY_RTD_QC_SUPPORT`) by looking for the red/green/blue sequence with 500 ms delays.
4. Ask on the bench (no monitor writes) whether the blue survives a power cycle with no DDC/CI traffic. Survival points to a latched register; loss points to a runtime path.
