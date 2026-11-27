# REPORT: where the "No Signal" blue comes from (UPERFECT M245T01)

Offline static analysis only. Monitor not touched. `firmware/` only read. No patch written.

## Summary

**Source:** a small function at **bank 8, local 0xC5FF** (file 0x8C5FF). It sets the D-domain background to R=0, G=0, **B=0xFF**, then enables force-to-background. The two callers are OSD timer-event cases (0x8C47C, 0x8C4C7). They draw a message and turn the backlight on.

**Confidence:** high that this code writes the blue. It is static only: never observed executing, and the patch is untested.

**Proposed patch (blue to black, 1 byte):**

| File offset | Bank:addr | Old | New | Instruction |
|---|---|---|---|---|
| **0x08C600** | 8:C600 | `FF` | `00` | `MOV R3,#0xFF` becomes `MOV R3,#0x00` |

Context at 0x08C5FF: `7B FF E4 FD FF 12 07 8D D2 03 12 07 93 22`.
After the patch the backlight still comes on, with the OSD text on black.

**Correction to the brief:** there is a second, 8-bit background setter, `3:FCB7`. It reaches port 0x6D by `INC DPTR` from 0x6C, so a search for `90 00 6D` misses it. The brief's `3:E906` (10-bit) is not used in the no-signal flow.

## 1. The blue write

### 8:C5FF "show blue background" (file 0x8C5FF)

```
C5FF 7bff    MOV R3,#0xff      ; B = 0xFF   <-- patch the FF at 0x8C600
C601 e4      CLR A
C602 fd      MOV R5,A          ; G = 0
C603 ff      MOV R7,A          ; R = 0
C604 12078d  LCALL 0x078d      ; trampoline -> bank3:FCB7
C607 d203    SETB 0x03
C609 120793  LCALL 0x0793      ; trampoline -> bank3:FE12 (force-bg = bit 0x03)
C60C 22      RET
```
```c
void FUN_CODE_c5ff(void) { T_b3_FCB7(0xff,0,0); _0_3 = 1; T_b3_FE12(); }
```
The decompiler lists Keil arguments out of order. Per the assembly: R7=R=0, R5=G=0, R3=B=0xFF.

### 3:FCB7, 8-bit background setter (file 0x3FCB7)

```
FCB7 12fea5  LCALL 0xfea5      ; DPTR=0x006C, clear bit5
FCBA e0      MOVX A,@DPTR
FCBB 54df    ANL A,#0xdf
FCBD 4420    ORL A,#0x20       ; reset colour port index
FCBF f0      MOVX @DPTR,A
FCC0 a3      INC DPTR          ; 0x006D
FCC1 ef f0   R
FCC3 ed f0   G
FCC5 eb f0   B
FCC7 e4      CLR A
FCC8 12fea4  LCALL 0xfea4      ; 4th byte 0, then clear 0x6C bit5

FEA4 f0        MOVX @DPTR,A
FEA5 90006c    MOV DPTR,#0x6c
FEA8 e0 54df f0 22
```
```c
void b3_FCB7(...) { FUN_CODE_fea5(); *p = *p & 0xdf | 0x20; p++; *p = R; *p = G; *p = B; FUN_CODE_fea4(0); }
```
The port receives `00 00 FF 00`, matching the live test (`00,00,FF`).

### 3:FE12, force-to-background (file 0x3FE12)

`MOV DPTR,#0x28; MOVX A; ANL A,#0xDF; JNB 0x03,+; ORL A,#0x20; MOVX @DPTR,A; RET`

## 2. Callers and the no-signal flow

### 8:C42B, OSD timer-event dispatcher (file 0x8C42B)

Index = XDATA `E54D` - 1, `JMP @A+DPTR` into an LJMP table at 8:C446. Reached from `8:FE58 LJMP 0xC42B` (after `LCALL 0xB5B6`).

```c
void FUN_CODE_c42b(void) {
  if (DAT_e54d - 1U < 0x12) { /* jump table 0xC446 */ return; }
  DAT_e54d = 0;
}
```
Ghidra does not decompile the case bodies, so they are assembly only.

**Cases E54D = 1 and 2 (file 0x8C47C)**
```
C47C 12c5ff  LCALL 0xc5ff      ; BLUE
C47F e4 ff   R7 = 0
C481 12c60d  LCALL 0xc60d      ; draw message 0, backlight ON
C484 90e1e1 e0 643c 7003 02c5e9 ; if E1E1 == 0x3C, done
C48F 7d06 7f60 7eea 02c586     ; else arm timer: event 6, 0xEA60 = 60000
```

**Case E54D = 7 (file 0x8C4B8)**
```
C4B8 12c5ef 12d2ac 74d9 f0 12104b 12d2f9
C4C7 12c5ff  LCALL 0xc5ff      ; BLUE
C4CA 121051  LCALL 0x1051      ; -> 7:F01A, draws OSD
C4CD 800e    SJMP 0xc4dd  ... C5E4 7f02 1204ed ; backlight ON
```

### 8:C60D, message then backlight on (file 0x8C60D)
```
C60D 12107b  LCALL 0x107b      ; -> 7:A872, OSD message draw (loads menu palette)
C610 7f02    MOV R7,#2         ; _BACKLIGHT_ON
C612 1204ed  LCALL 0x04ed      ; -> 2:A349
C615 22      RET
```
```c
void FUN_CODE_c60d(void) { T_b7_A872(); T_b2_A349(2); }
```

### Who sets E54D: 6:9C1C, event handler (R7 = event, table at 6:9C34)

| Event | Site | Action |
|---|---|---|
| 3 | 6:9CAA (file 0x69CAA) | panel action 1 (off), force-bg on, pattern generator off |
| 4 | 6:9CC9 | E54D = 2 (blue message later) |
| 5 | 6:9CD0 | E54D = 1 (blue message later) |

Event 3 fits the observed first phase (force-bg, backlight off, black). That match is an inference.
`E54D = 7` is also set at 6:9E6A and 8:B696.
6:9C1C is called via trampoline 0x0F97 from 2:F371, itself called from 5:D66A.

**Unknown:** which of E54D = 1, 2 or 7 is the live "No Signal" case. All three go through 8:C5FF, so the patch covers them.

## 3. Backlight function: 2:A349 (file 0x2A349), trampoline 0x04ED

R7: 0 = panel on, 1 = panel off, 2 = backlight on, 3 = backlight off. This matches the SDK's `UserCommonInterfacePanelPowerAction`.
`XDATA FE25` is backlight enable, active low. `FE24` is panel power. Pin meaning is inferred from code and the SDK demo board (P8.5/P8.4), not traced on this PCB.

```
A387 ...      case 1: A392 90fe25 7401 f0   FE25=1 (BL off), then FE24=0
A3CC 12b9dc 7010 12a47f ...   case 2: A420 e4 90fe25 f0   FE25=0 (BL ON)
A431 ...      case 3: A43D 90fe25 7401 f0   FE25=1 (BL off)
```
```c
if (action == 1) { ...; DAT_fe25 = 1; ...; DAT_fe24 = 0; timer(...); return; }
if (action == 2) { if (state == 0) panel_on(); ...; DAT_fe25 = 0; state |= 3; return; }
if (action == 3) { if (state != 0 && state != 4) { DAT_fe25 = 1; state |= 4; } }
/* action 0: panel on (FE24 = 1 in FUN_a47f), state |= 1 */
```

## 4. Every path to the background colour port (0x006D) and 0x006C bit5

Port writers: only `3:E906` and `3:FCB7`. `0x6C` bit5 is touched only by these two and their helper `3:FEA4/FEA5`. Other `90 00 6C` sites change other bits (3:5FA4/5FC4 bit0; 9:6BEA, 6C53, 7065, 7160, 719F). No register table or generic-helper call with address 0x006C/0x006D was found.

### Callers of 3:FCB7 (`LCALL/LJMP 0x078D`, whole-image byte search)

| Site (file) | Colour |
|---|---|
| **8:C604 (0x8C604)** | **blue 0,0,FF** |
| 2:CECE (0x2CECE) | table 2:3668 = R, G, B, black, white. Cycling routine 2:CE6D with backlight on (factory/burn-in, inferred) |
| 2:4BEC (0x24BEC) | variable, from XDATA E600-E602 |
| 2:B189, 2:CA9C, 6:C81C | black |

### 3:E906, 10-bit setter (file 0x3E906)
```
E906 90dc50 ee f0 a3 ef f0   save R
E90E 12fea5 e0 54df 4420 f0  reset port index
E917.. R>>2 -> E927 90006d f0 ; G>>2 -> E937 ; B>>2 -> E947 ; low bits -> E96A 90006d 12fea4
```
```c
FUN_e906(R,G,B) { index_reset(); P6D = R>>2; P6D = G>>2; P6D = B>>2; P6D = low2bits; index_off(); }
```
Callers: 3:3B06 and wrapper 3:F794 (callers 3:366C, 37A0, 37E2, 381A), all inside 3:3569. 3:3569 is reached only from the DDC/CI command switch 9:2823: opcode `XDATA DDB9 == 0xFC` at 9:2C08 `LJMP 0x127F`. Its sub-step 2 also loads blue (3:372B `R3=0xFC, R2=3`). It is host-driven display calibration, not the no-signal flow. Leave it alone.

### Not the source
- Pattern generator (`07F3-07F5`, setters 3:EBD7 and 3:FD32): loads black, table 3:2972 (0x300,0x140,0x140), or DDC-driven values.
- OSD palettes: all 10 calls of the loader (byte search) use R7=1 (menu palette), which has no pure blue.

## 5. Alternative: leave the backlight off (not recommended)

NOP the call at file 0x8C612: `12 04 ED` to `00 00 00`. It also affects E54D = 3 (8:C4A4 calls C60D), and E54D = 7 uses a different backlight call (0x8C5E6, `12 04 ED`). The screen then shows no message, and wake behaviour is untested. The colour patch is safer.

## Before any flashing (not done here)
- Flash self-check: examined later, none found. See "Checksum check" below.
- Flash is erased by sector: the patch means rewriting the 4 KiB sector 0x8C000-0x8CFFF.
- Keep both dumps unchanged and have a tested ISP restore path.

## Reproduce
`ghidra/run.sh` splits a copy of the dump into 64 KiB bank images and runs headless Ghidra (banks 0-9, 11). `Setup.java` stubs the 726 trampolines (Ghidra memory only) and seeds Keil switch tables and `JMP @A+DPTR` tables. Output: `ghidra/out/bankN.asm` and `.c`. Trampoline format: `90 hh ll 02 02 ss`, bank = (0x200+ss - 0x22F) / 0x12.
The first pass without jump-table seeding missed 8:C5FF.

## Checksum check

Offline only. `firmware/` only read.

### Verdict

**Yes, safe to patch the 1 byte with no other changes. Confidence: high (about 90%), static analysis only.**
No firmware code was found that verifies code flash, and no stored image checksum was found.
`firmware/m245t01-patched-blackbg.bin` differs from dump-a at exactly one byte: `0x8C600 FF -> 00`
(SHA-256 `93159bb1ea366544d1a3ef032706c5f8f84d7ce6cdf340f68ade8e053ad55dd4`).

### 1. Does any code check code flash? Not found

- **CRC engine unused.** No `MOV DPTR,#0xFF6F..0xFF75` anywhere in banks 0-9 (byte search `90 FF xx`), and no register-built pointer to FF6x/FF7x. CRC end address (FF73/74) is never set and the result (FF75) never read. `FF78-FF7C` are used, but as a flash read/program port (below), not CRC.
- **MOVC loops.** Only 8 functions loop around `MOVC`: C startup init 0:229B, switch helper 0:198D, and 0:DAEE, 3:423C, 8:CB7B, 8:F550, 9:3CB6, 9:4287. None walks a large flash range against a stored value. Reset is `02 22 9B` (LJMP 0x229B), then normal C init.
- **Flash read port** `9:5B43` (trampoline 0x06F1) copies flash to XDATA: `FF78`=bank, `FF79/7A`=address, `FF7B`=data. Its guard is `bank >= XDATA FFFD` (written 0 at 0:EADA), so it *could* read code banks. The callers with constant banks use 0x0B or 0x0C (data). The small callers at 0:E94D, 0:ED90, 0:F76C read 1-2 bytes with a bank from a table descriptor.
- **One CRC routine exists: 1:F491** (bit-wise CRC-8 over a RAM buffer, length in R5). It checks settings records read from bank 0x0C, e.g.
  `E7AA LCALL 0xfe57` (R7=0x0C, 16 bytes), `E7B3 MOV R5,#0xf; E7B5 LCALL 0xf491`, `E7C1 DPTR=0xdc59 ... XRL A,R7; JNZ` (compare with byte 15).
  Other callers: 1:E863, 8:B456, 8:B56A, 8:D7A0, 8:E391. None covers bank 8.
- **OTA / self-test.** No update path that verifies the image was found. The flash test code inside 2:8568 is dead: `8568 CLR 0x02; 856A JB 0x02,0x8570; 856D LJMP 0x877F`.

### 2. Stored checksum or signature bytes? None found

- 0x0000 is the interrupt vector table (`02 22 9B 02 1E AA 22 FF...`), with no header or tag.
- Banks end in ordinary code or `22` (RET) filler, then `FF` up to 0xFFFF. `0xFFE0-0xFFFF` is blank in every bank.
- No Realtek image tag found by string search. Only `ver(2.2))` appears.
- No code reads a code-flash checksum, so no byte needs updating.

### 3. What is in sector 0x8C000-0x8CFFF

**Only executable code. No user data or NVRAM.**
- 94 function entries between 8:C000 and 8:CFFF. The sector starts mid-function (code from 8:BFFD continues at C000), and the last function (8:CFF6) is at the end of the sector. Check the sector as a whole 4096 bytes, not by function.
- It includes the OSD handlers 8:C415, the timer-event dispatcher 8:C42B (table 8:C446) and the patched 8:C5FF. Flashing this sector therefore rewrites live code.
- 3,614 bytes disassembled. The one gap, 8:C622-C804 (483 bytes), is code Ghidra did not reach.
- No constant-bank flash-to-XDATA copy reads this sector.

**Runtime flash writes** (erase `1:FC5D`, trampoline 0x0D5D; program `1:EEA8`, trampoline 0x0D45):

| Site | Bank |
|---|---|
| 8:B309, 8:D762 (erase); 1:E991, 1:E9E1 and bank-8 writes | 0x0C (settings, 0xCB000-0xCCFFF in this dump) |
| 3:3703, 3:3B58 (erase); bank-3 writes (DDC calibration) | 0x0B (0xB0000-0xBA200) |
| 2:85B2 erase, 2:85C4 write (bank 0) | dead code, see above |

No constant write or erase targets bank 8. A few calibration writes take the bank from a table (wrapper 3:EE4F: 0x0B when index >= 5, otherwise a table value that was not traced).
Settings in bank 0x0C change at runtime, so a fresh dump may differ there. A 1-sector write to 0x8C000 does not touch them.

### Limits

- Static only. Mask ROM or hardware boot checks cannot be seen in a flash image. None is known to this analysis.
- Banks 10-15 were treated as data: no code trampolines target them.
- Computed loops reading code through generic pointers were not all traced one by one.
- This verdict is about self-checking only. It does not cover flashing risk: an interrupted sector write leaves bank 8 code corrupt. Confirm ISP recovery works first, write the 4 KiB sector, and read back and compare the whole 1 MiB.

## Flash protection

Offline only. Live status as supplied (not read here): SR1=0xFC (SRP0=1, BP4..BP0=11111), SR2=0x40 (CMP=1), JEDEC 85 60 14.

**Verdict: yes, 0x08C600 and 0x0F0000 are both writable with the current status. No block is protected.** (Assumes WPS=0 if the part is the SH variant, see below.)

### 1. Datasheet protection table

Puya `P25Q80H Datasheet V1.7`, "P25Q80H Protected Area Sizes (CMP bit = 1)", page 16 of 70:

```
BP4  BP3  BP2  BP1  BP0   Blocks   Addresses   Density   Portion
 x    x    1    1    x    NONE     NONE        NONE      NONE
```
`P25Q80SH` V1.5, Table 6-2 (WPS=0, CMP=1), has the same row. BP4..BP0=11111 matches it, so the protected range is **none**.
(With CMP=0 the same BP bits protect ALL, 000000H-0FFFFFH.)

- H: https://www.puyasemi.com/download_path/%E6%95%B0%E6%8D%AE%E6%89%8B%E5%86%8C/Flash%20%E8%8A%AF%E7%89%87/P25Q80H_Datasheet_V1.7.pdf
- SH: https://www.puyasemi.com/download_path/%E6%95%B0%E6%8D%AE%E6%89%8B%E5%86%8C/Flash%20%E8%8A%AF%E7%89%87/P25Q80SH_Datasheet_V1.5.pdf

Both variants answer RDID with 85 60 14. They differ in two ways that matter:
- **One-byte WRSR (01h).** H: "the CMP and QE and SRP1 bits will be cleared to 0". SH: "the Status Register-1 will not be affected". The firmware restores with one byte (below). On an H part that would clear CMP and protect the whole chip. Live CMP=1 therefore suggests SH behaviour, or no runtime flash write since CMP was last set. This is an inference.
- **WPS.** SH has a Configure Register bit WPS (read with 15h, bit 2). WPS=1 replaces BP/CMP with individual block locks that are all set at power-up. Default is 0. The live value was not supplied: **read it before flashing.**

SRP0=1 only locks the status register while WP# is low. It does not protect the array.

### 2. Firmware: yes, it changes protection around every write and restores it

**Flash type.** Table at 1:BAF4 (13 bytes per entry, 0x5C entries), index in XDATA E62C. The only 85 60 14 entry is index 0x39, at 1:BDD9 (file 0x1BDD9):
```
9f 85 60 14 90 85 13 00 06 04 20 02 fc
[9]=04 WRDI   [10]=20 sector erase   [11]=02 page program   [12]=FC restore value for SR1
```

**Order.**
- Erase `1:FC5D`: `FC85 LCALL 0xbfdb` (unprotect), erase using table[10], `FCC3 LCALL 0xf2bd` (restore).
- Program `1:EEA8`: `F025 LCALL 0xf0a2` (which calls BFDB), page loop, `F073 LCALL 0xf2bd` (restore).

**Unprotect, 1:BFDB(bank R7, sector R5)** dispatches on E62C (table 1:C009). Index 0x39 goes to **1:CA20** (file 0x1CA20):
```
CA20 DPTR=0xdd0b ; bank ; if >= 0x10 goto CB0D
CA2C JMP @A+DPTR            ; per-bank case, sets DD0D = SR1
...  DPTR=0xdd0e ; MOV A,#0x40 ; MOVX     ; SR2 = 0x40 (CMP=1)   (CAC9/CB05..CB0A)
CB13 LJMP 0xe62d
E62D R7=DD0D, R5=DD0E ; E635 CLR 0x06 ; E637 LCALL 0xfdaa ; then E667: FF6D=0x02, FF61=0xFF
FDAA LCALL 0xed32 (FE26=1) ; FDB5 FF60=0x70 ; FDB8 FF61=0x01 (WRSR) ; FF64=SR1 ; FF65=SR2 ; FF60|=1
```

| Bank written | SR1 (SR2=0x40) | Left unprotected |
|---|---|---|
| 0, sector 0 / 1 / 2-3 / 4-7 / 8-15 | 66 / 6A / 6E / 72 / 26 | first 4K / 8K / 16K / 32K / 64K |
| 1 | 2A | 000000-01FFFF |
| 2-3 | 2E | 000000-03FFFF |
| 4-7 | 32 | 000000-07FFFF |
| 8-11 (includes **0x0B**) | 12 | 080000-0FFFFF |
| 12-13 (includes **0x0C**) | 0E | 0C0000-0FFFFF |
| 14 | 0A | 0E0000-0FFFFF |
| 15, sector 15 / 14 / 12-13 / 8-11 / 0-7 | 46 / 4A / 4E / 52 / 06 | 4K / 8K / 16K / 32K / 64K at top |
| >= 16 | 02, SR2=00 | all |

The values match the datasheet CMP=1 table, which confirms the decoding.

**Restore, 1:F2BD** dispatches on E62C (table 1:F2DA). Index 0x39 goes to **1:F3F5** (file 0x1F3F5):
```
F3F5 LCALL 0xecb6        ; R7 = table[12] = 0xFC
F3F8 CLR 0x06 ; F3FA LCALL 0xfe9e
FE9E LCALL 0xed32 ; FEA9 FF60=0x68 ; FEAC LCALL 0xec9c
EC9C FF61=0x01 (WRSR) ; FF64=R7 (0xFC) ; FF60|=1          ; one data byte only
F3FD..F46A -> table[9]=0x04 ; F483 LCALL 0xfec7 : FF60=0x20, FF61=0x04 (WRDI), FF60=0x21
F486 FF6D=0xFF ; FF61=0xFF
```
So after any runtime write the firmware writes **SR1=0xFC** and does not send SR2. On an SH part SR2 stays 0x40, which gives exactly the live status 0xFC/0x40, i.e. unprotected.

**WREN.** No explicit `FF61=0x06` or `0x50` is written on this path. The FF60 values 0x68 and 0x70 select the Realtek engine's "write after WREN" instruction type with 1 or 2 data bytes, so the hardware sends WREN (table[8]=06) itself. Bit 0x06 is clear, so the volatile/EWSR forms (0x88/0x90) are not used. This engine behaviour is inferred from the Realtek convention, not shown by the code. The `FF63=0x06/0x50` writes in 1:EEA8 (EFF1, F01C, F02B, F06D) require FF60 type 0x80, which this part's path does not set.
