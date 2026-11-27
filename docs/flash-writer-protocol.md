# Report: `byte-program` in `rtd-isp.swift` (replaces the sector writer)

Status: **compiles** (`swiftc -O`, exit 0, no warnings). **Never executed.** No mode, old or new, has been run in
this task, so every hardware behaviour below is untested on this monitor. `firmware/*.bin` were only read.

The patch is one byte, `0x08C600` `FF -> 00`. Bits only go 1 -> 0, so there is no erase. All sector erase,
sector program, unprotect and status-restore code is removed. The status register is never written.

## Modes

| Mode | Changes flash | What it does |
|---|---|---|
| `status` | no | JEDEC, SR1 (`05`), SR2 (`35`), `0x6F` engine state |
| `readback <addr> <len>` | no | hex dump, then every byte differing from dump-a |
| `sector-dry <image> <addr>` | no | live vs image and vs dump-a; refuses unless live = dump-a and image differs only in that sector |
| `byte-program <addr> <value> --i-have-a-backup` | **one byte** | below |

## Protocol

`FS` = awto-au/awto-ddc `scripts/rtd_flash_sector.py`, `PR` = `scripts/rtd_isp_probe.py` (default branch),
`GH` = ghent360/RTD-2660-Programmer `RTD Programmer/main.cpp`; all fetched 2026-11-27. `DS` = Puya P25Q80H datasheet
V1.7 (puyasemi.com). I2C slave 0x4A.

| # | Step (Swift function) | ISP registers | Source |
|---|---|---|---|
| 1 | Enter ISP (`enterIsp`) | `6F<-80`; require bit7 | PR 138-141 |
| 2 | JEDEC (`jedec`) | `60<-46, 61<-9F, 60<-47`; poll `60` bit0; read `67 68 69` = `85 60 14` | PR 66-72 |
| 3 | Status (`sr1`, `sr2`) | `60<-42, 61<-05 or 35, 60<-43`; poll; read `67` | GH 67-106; FS 155-165; bits and `35`: DS 10.5 |
| 4 | Engine preflight (`openFlash`) | read `6F`: bit4 = 1, bit5 = 0 | bits FS 70-72; check is new |
| 5 | Read target and both neighbour sectors twice (`readFlash`) | per 1 KiB: `60<-46, 61<-03, 64..66<-addr, 60<-47`; poll; 16 x 64-byte reads of `70` | PR 82-92; GH 110-124 |
| 6 | Opcode setup | `62<-06 63<-50 6A<-03 6B<-0B 6D<-02 6E<-05` | GH 178-183; FS 76-77 |
| 7 | Length = 1 byte | `71<-00` (length - 1); read back | GH 323-324 "program size-1" (they use 255). **Length 1 is not exercised by either tool** |
| 8 | WREN `06` | `60<-20, 61<-06, 60<-21` (type 1, no data); poll | GH 59-80 (encoding). Sending a bare WREN this way is new |
| 9 | Confirm WREN | RDSR: WEL = 1, BP = 0 | DS 10.8 (WEL) |
| 10 | Address | `64<-A23:16, 65<-A15:8, 66<-A7:0`; read back all three | GH 327-329; readback FS 348-359 |
| 11 | Buffer ready | poll `6F` bit4 = 1 | FS 449-451 |
| 12 | Data | one write: `70<-value` | GH 331-337; FS 127-132 (single-byte writes to `70`) |
| 13 | Start PP `02` | read `6F`, `6F<-v\|20`; poll bit5 = 0 | FS 453-456. GH 339 writes `A0` (same start value) but polls bit6 |
| 14 | Wait flash | RDSR until WIP = 0 | FS 243-247 |
| 15 | Readback | same range as step 5; compare with the pre-read plus the one intended byte; list diffs vs dump-a | new |

The reference's own "WREN" routine (FS 315-327) is not used: `60<-70` encodes type 3 with **two data bytes** and
`61<-01` is WRSR (GH 59-95), so it appears to write the status register.

## Abort conditions

Exit codes: 0 OK, 2 bus error before programming, 3 refused, 5 failed after programming started.

**Before the monitor is halted** (3): not exactly one external display; bad arguments; missing
`--i-have-a-backup`; address not `0x`-hex or >= 1 MiB; value > `0xFF`; address in banks 11-12
(`0x0B0000-0x0CFFFF`); dump-a missing or SHA-256 not `068466f3...5cd5`.

**After ISP entry, nothing programmed** (3, or 2 for a bus error): ISP bit not set; JEDEC mismatch; **any BP4..BP0
bit or CMP set** (printed); WIP, WEL or suspend set; `6F` not idle with buffer ready; two pre-reads differ;
`(live & value) != value`; live already equals value; `71` does not read back `00`; WEL not set after WREN; address
readback mismatch; buffer not ready.

**From the data write onward** (5): no retries. Any error still leads to the readback. `OK` only if no step failed
and the three sectors equal the pre-read with exactly the target byte changed. Every unexpected byte is listed.
Signals (`SIGINT`, `SIGTERM`, `SIGHUP`, `SIGQUIT`, `SIGTSTP`, `SIGPIPE`) are ignored from step 6 on.

Power-cycle the monitor between any two runs: a failed run can leave a byte in the page buffer or WEL set.

## Unknowns and chip-specific assumptions

| Assumption | If wrong | Caught by |
|---|---|---|
| `71<-00` programs exactly 1 byte | up to 256 stale buffer bytes get programmed (bits cleared, needs erase to undo) | readback; **the rehearsal exists to catch this first** |
| `6F` bit4 = ready, bit5 = start/busy (from RTD2795; GH polls bit6) | nothing programmed, or poll ends early | preflight checks idle only; WIP poll and readback |
| Engine type 1 / type 2 encoding fits our scaler | WREN not set, or wrong command | WEL check, readback |
| `64..66` and `71` read back | tool refuses | readback checks |
| Page engine tolerates WEL already set / sends its own WREN | no change | readback |
| P25Q80**H** status layout | protection misread | flash then ignores the write; readback |
| macOS does not resend a NAKed I2C write | a duplicate data byte, ignored if length is 1 | readback |
| WP# pin | not relevant: it only locks the status register, which is never written | |

Our scaler chip is not identified. The rehearsal covers a low address byte of `00`, which matches the real target.
It does not cover other addresses.

No erase exists in this tool, so **a wrong 1 -> 0 change cannot be undone with it.** Undoing the real patch
(`00 -> FF`) needs a 4 KiB erase, by an external SPI programmer or a separately reviewed tool.

## Rehearsal address

`0x0F0000`, bank 15. Checked offline: bank 15 (`0x0F0000-0x0FFFFF`) has 0 non-`FF` bytes in both dump-a and dump-b;
sector `0x0EF000` is also all `FF`. Per the main session, banks 13-15 are never written by firmware
(`REPORT-ghidra.md` notes one calibration write path whose bank comes from an untraced table). The rehearsal leaves
`0x0F0000 = 00` permanently.

## Commands

Project folder, monitor on USB-C (through the dock or direct, not HDMI), no other external display. Power-cycle the monitor after **each**
`rtd-isp` command and check that it boots.

```sh
cd <repo>/tools
swiftc -O rtd-isp.swift -o /tmp/rtd-isp

# offline: bank 15 is blank (expect: 0)
python3 -I -c "print(sum(b!=255 for b in open('firmware/m245t01-dump-a.bin','rb').read()[0xF0000:]))"

# read only
caffeinate -dis /tmp/rtd-isp status
caffeinate -dis /tmp/rtd-isp readback 0x0F0000 0x1000      # expect: 0 bytes differ (all FF)
```

**Rehearsal (writes flash):**

```sh
caffeinate -dis /tmp/rtd-isp byte-program 0x0F0000 0x00 --i-have-a-backup
```

Expect `readback 0x0F0000 = 00`, exactly 1 byte differing from dump-a in `0x0EF000..0x0F1FFF`, and `OK:`.
Power-cycle, then check the whole chip:

```sh
caffeinate -dis /tmp/rtd-isp dump /tmp/after-rehearsal.bin
cmp -l /tmp/after-rehearsal.bin firmware/m245t01-dump-a.bin | awk '$1<720897 || $1>851968'
```

Expect one line: `983041   0 377` (offsets are 1-based, values octal; banks 11-12 are filtered out because settings
change at run time). **Any other line, or any non-OK result: stop, do not run the real command.**

**Real patch (writes flash):**

```sh
caffeinate -dis /tmp/rtd-isp sector-dry firmware/m245t01-patched-blackbg.bin 0x08C000
```

Expect one difference, `0x08C600 live FF image 00`, and `DRY RUN OK ... 0`. Power-cycle, then:

```sh
caffeinate -dis /tmp/rtd-isp byte-program 0x08C600 0x00 --i-have-a-backup
```

Expect `readback 0x08C600 = 00`, exactly 1 byte differing from dump-a in `0x08B000..0x08DFFF`, and `OK:`.
Power-cycle, then:

```sh
caffeinate -dis /tmp/rtd-isp dump /tmp/after.bin
cmp -l /tmp/after.bin firmware/m245t01-dump-a.bin | awk '$1<720897 || $1>851968'
```

Expect two lines: `574977   0 377` and `983041   0 377`. Power-cycle.

`sector-dry` refuses after a successful patch (live no longer equals dump-a); use `readback` instead.
