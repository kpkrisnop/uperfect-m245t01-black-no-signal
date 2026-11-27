// Realtek RTD scaler ISP over DisplayPort AUX on Apple Silicon (IOAVService).
// Protocol ported from github.com/awto-au/awto-ddc scripts/rtd_isp_probe.py and rtd_flash_sector.py
// (themselves from naorunaoru/rtdflash). See REPORT-writer.md.
//
//   rtd-isp regs              read ISP regs 0x6F 0x60 0x67-0x69, no writes
//   rtd-isp jedec             enter ISP (0x6F <- 0x80), read SPI flash JEDEC ID, reset scaler
//   rtd-isp dump <out.bin>    enter ISP, dump whole flash (SPI READ only), reset scaler
//   rtd-isp status            enter ISP, read JEDEC + flash status registers (read only)
//   rtd-isp readback <addr> <len>                     enter ISP, hex dump a flash range (read only)
//   rtd-isp sector-dry <image.bin> <sector_addr>      compare live sector, image and backup (read only)
//   rtd-isp byte-program <addr> <value> --i-have-a-backup     PROGRAMS ONE BYTE, bits 1->0 only, no erase
//
// Entering ISP halts the monitor (black screen). Reset (0xEE <- 0x02) does not reboot our chip: power-cycle it.
// Only byte-program changes flash. Nothing here erases or writes the flash status register.
// Run readback, sector-dry and byte-program from the project folder (they need firmware/).
import CryptoKit
import Foundation
import IOKit

typealias IOAVService = CFTypeRef
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ a: CFAllocator?, _ s: io_service_t) -> Unmanaged<IOAVService>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ s: IOAVService, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ s: IOAVService, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn

let ISP: UInt32 = 0x4A

func externalService() -> IOAVService {
    var it = io_iterator_t()
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)
    while case let s = IOIteratorNext(it), s != 0 {
        let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        if loc == "External", let a = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue() { return a }
    }
    fputs("no external display on a direct USB-C/DP link\n", stderr); exit(1)
}
let svc = externalService()

struct BusError: Error { let what: String }

// ponytail: 3 retries per transfer; AUX occasionally NAKs, a dump of MiBs must survive that.
func read(_ reg: UInt8, _ n: Int) throws -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: n)
    for _ in 0..<3 {
        if IOAVServiceReadI2C(svc, ISP, UInt32(reg), &buf, UInt32(n)) == 0 { return buf }
        usleep(2000)
    }
    throw BusError(what: String(format: "read reg 0x%02X", reg))
}
func read(_ reg: UInt8) throws -> UInt8 { try read(reg, 1)[0] }
func write(_ reg: UInt8, _ val: UInt8) throws {
    var v = [val]
    for _ in 0..<3 {
        if IOAVServiceWriteI2C(svc, ISP, UInt32(reg), &v, 1) == 0 { return }
        usleep(2000)
    }
    throw BusError(what: String(format: "write reg 0x%02X", reg))
}
func poll(_ ctx: String, _ limit: Double = 1.0, _ done: () throws -> Bool) throws {
    let t0 = Date()
    while true {
        if try done() { return }
        if Date().timeIntervalSince(t0) > limit { throw BusError(what: "timeout: \(ctx)") }
    }
}
func waitSpi(_ ctx: String) throws {
    try poll("SPI engine busy: \(ctx)") { try read(0x60) & 1 == 0 }
}
func enterIsp() throws {
    try write(0x6F, 0x80)
    let v = try read(0x6F)
    print(String(format: "0x6F after enter = 0x%02X", v))
    guard v & 0x80 != 0 else { throw BusError(what: "ISP mode not enabled") }
}
func resetScaler() {
    _ = try? write(0xEE, 0x02)   // scaler reboots and usually drops this transfer: expected
    print("scaler reset sent (0xEE <- 0x02); if the monitor stays black, power-cycle it")
}
func jedec() throws -> [UInt8] {
    try write(0x60, 0x46); try write(0x61, 0x9F); try write(0x60, 0x47)
    try waitSpi("JEDEC")
    return [try read(0x67), try read(0x68), try read(0x69)]
}
func dump(_ size: Int, _ out: URL, block: Int = 64) throws {
    FileManager.default.createFile(atPath: out.path, contents: nil)
    let f = try FileHandle(forWritingTo: out)
    defer { try? f.close() }
    let t0 = Date()
    for addr in stride(from: 0, to: size, by: 1024) {
        try write(0x60, 0x46); try write(0x61, 0x03)
        try write(0x64, UInt8((addr >> 16) & 0xFF)); try write(0x65, UInt8((addr >> 8) & 0xFF))
        try write(0x66, UInt8(addr & 0xFF))
        try write(0x60, 0x47)
        try waitSpi(String(format: "READ at 0x%06X", addr))
        var chunk = [UInt8]()
        for _ in 0..<(1024 / block) { chunk += try read(0x70, block) }
        f.write(Data(chunk))
        if addr % (64 * 1024) == 0 {
            print(String(format: "  0x%06X / 0x%06X  %.0fs", addr, size, Date().timeIntervalSince(t0)))
        }
    }
    print(String(format: "dumped %d bytes to %@ in %.0fs", size, out.path, Date().timeIntervalSince(t0)))
}

// MARK: - status, readback, sector-dry, byte-program

let SECTOR = 4096
let FLASH_SIZE = 1 << 20
let JEDEC_EXPECT: [UInt8] = [0x85, 0x60, 0x14]          // Puya P25Q80
let BACKUP_PATH = ProcessInfo.processInfo.environment["RTD_BACKUP"] ?? "firmware/dump-a.bin"
let BACKUP_SHA256 = ProcessInfo.processInfo.environment["RTD_BACKUP_SHA256"] ?? ""   // SHA-256 of YOUR verified dump (two identical reads)
let LIVE_DATA = 0x0B0000..<0x0D0000                     // banks 11-12: calibration and settings, never program
// P25Q80H status bits (datasheet V1.7): SR1 = SRP0 BP4..BP0 WEL WIP; SR2 = SUS1 CMP LB3..LB1 SUS2 QE SRP1
let SR1_BP: UInt8 = 0x7C, SR2_CMP: UInt8 = 0x40, SR2_SUS: UInt8 = 0x84

func die(_ s: String) -> Never { fputs("refuse: \(s)\n", stderr); exit(3) }
func hex(_ v: Int) -> String { String(format: "0x%06X", v) }
func parseHex(_ s: String) -> Int? {
    let l = s.lowercased()
    return l.hasPrefix("0x") ? Int(l.dropFirst(2), radix: 16) : nil
}

// One attempt only. For anything that must not be repeated blindly: engine "go", program start, 0x70 data.
func writeOnce(_ reg: UInt8, _ val: UInt8) throws {
    var v = [val]
    if IOAVServiceWriteI2C(svc, ISP, UInt32(reg), &v, 1) != 0 { throw BusError(what: String(format: "write reg 0x%02X", reg)) }
}

// SPI engine common command: 0x60 = type<<5 | nWrite<<3 | nRead<<1 | go (here without write bytes).
// type 1 = write, 2 = read (ghent360 RTD-2660-Programmer SPICommonCommand).
func spi(type: UInt8, op: UInt8, nr: Int = 0) throws -> [UInt8] {
    let v = type << 5 | UInt8(nr) << 1
    try write(0x60, v); try write(0x61, op)
    try writeOnce(0x60, v | 1)
    try waitSpi(String(format: "op 0x%02X", op))
    return try (0..<nr).map { try read(0x67 + UInt8($0)) }
}
func sr1() throws -> UInt8 { try spi(type: 2, op: 0x05, nr: 1)[0] }
func sr2() throws -> UInt8 { try spi(type: 2, op: 0x35, nr: 1)[0] }
func isProtected(_ s1: UInt8, _ s2: UInt8) -> Bool { s1 & SR1_BP != 0 || s2 & SR2_CMP != 0 }

func printStatus(_ s1: UInt8, _ s2: UInt8) {
    func bit(_ v: UInt8, _ n: Int) -> Int { Int(v >> n) & 1 }
    print(String(format: "SR1 = 0x%02X  SRP0=%d BP4..BP0=%d%d%d%d%d WEL=%d WIP=%d", s1, bit(s1, 7),
                 bit(s1, 6), bit(s1, 5), bit(s1, 4), bit(s1, 3), bit(s1, 2), bit(s1, 1), bit(s1, 0)))
    print(String(format: "SR2 = 0x%02X  SUS1=%d CMP=%d LB3..1=%d%d%d SUS2=%d QE=%d SRP1=%d", s2, bit(s2, 7), bit(s2, 6),
                 bit(s2, 5), bit(s2, 4), bit(s2, 3), bit(s2, 2), bit(s2, 1), bit(s2, 0)))
    print("block protect: " + (isProtected(s1, s2) ? "SET (BP or CMP non-zero)" : "none"))
}

// SPI READ in 1 KiB commands. The 0x70 FIFO is never re-read: a failed chunk restarts its whole command.
func readFlash(_ start: Int, _ count: Int) throws -> [UInt8] {
    var out = [UInt8]()
    for addr in stride(from: start, to: start + count, by: 1024) {
        var tries = 0
        while true {
            do {
                try write(0x60, 0x46); try write(0x61, 0x03)
                try write(0x64, UInt8((addr >> 16) & 0xFF)); try write(0x65, UInt8((addr >> 8) & 0xFF))
                try write(0x66, UInt8(addr & 0xFF))
                try writeOnce(0x60, 0x47)
                try waitSpi("READ at \(hex(addr))")
                var kb = [UInt8]()
                for _ in 0..<16 {
                    var buf = [UInt8](repeating: 0, count: 64)
                    guard IOAVServiceReadI2C(svc, ISP, 0x70, &buf, 64) == 0 else { throw BusError(what: "data read at \(hex(addr))") }
                    kb += buf
                }
                out += kb
                break
            } catch let e as BusError {
                tries += 1
                if tries == 3 { throw e }
            }
        }
    }
    return Array(out.prefix(count))
}

func loadBackup() -> [UInt8] {
    guard let b = FileManager.default.contents(atPath: BACKUP_PATH), b.count == FLASH_SIZE else {
        die("\(BACKUP_PATH) missing or not 1 MiB (run from the project folder)")
    }
    guard !BACKUP_SHA256.isEmpty else { die("set RTD_BACKUP_SHA256 to the SHA-256 of your verified dump (two identical dumps)") }
    guard SHA256.hash(data: b).map({ String(format: "%02x", $0) }).joined() == BACKUP_SHA256 else { die("backup SHA-256 mismatch") }
    return [UInt8](b)
}

// Prints every byte of `data` (flash contents from `start`) that differs from `ref` (a whole 1 MiB image).
func printDiffs(_ data: [UInt8], at start: Int, _ ref: [UInt8], _ name: String) {
    let d = data.indices.filter { data[$0] != ref[start + $0] }
    print("\(hex(start))..\(hex(start + data.count - 1)) vs \(name): \(d.count) bytes differ")
    for i in d { print(String(format: "  %@  live %02X  %@ %02X", hex(start + i), data[i], name, ref[start + i])) }
}

// Enter ISP, identify the flash, print status and the program engine state.
func openFlash() throws -> (UInt8, UInt8, Bool) {
    try enterIsp()
    print("MCU halted. Power-cycle the monitor when finished.")
    let id = try jedec()
    print("JEDEC ID = " + id.map { String(format: "%02x", $0) }.joined(separator: " "))
    guard id == JEDEC_EXPECT else { die("JEDEC is not 85 60 14") }
    let (s1, s2) = (try sr1(), try sr2())
    printStatus(s1, s2)
    let v = try read(0x6F)
    let idle = v & 0x10 != 0 && v & 0x20 == 0
    print(String(format: "0x6F = 0x%02X: page engine %@", v, idle ? "idle, buffer ready" : "NOT in the expected idle state"))
    return (s1, s2, idle)
}

func byteProgram(_ addr: Int, _ value: UInt8, _ backup: [UInt8]) throws -> Never {
    let (s1, s2, idle) = try openFlash()
    // P25Q80H/SH datasheet, CMP=1 table: BP4..BP0 = x x 1 1 x -> protected area NONE. Firmware's own restore value is
    // SR1=0xFC with SR2=0x40 (REPORT-ghidra.md "Flash protection"). SH variant: WPS (config reg 0x15 bit2) must be 0.
    let cr = try spi(type: 2, op: 0x15, nr: 1)[0]
    print(String(format: "CR (0x15) = 0x%02X  WPS=%d", cr, Int(cr >> 2) & 1))
    let knownNone = s1 & 0x7C == 0x7C && s2 & SR2_CMP != 0 && cr & 0x04 == 0
    guard !isProtected(s1, s2) || knownNone else { die("block-protect bits are set (see above). Status register is never written.") }
    guard s1 & 0x03 == 0, s2 & SR2_SUS == 0 else { die("flash busy, write-enabled or suspended (WIP/WEL/SUS)") }
    guard idle else { die("0x6F bits 4/5 do not match the reference program engine") }

    // The target sector and both neighbours, as one range clipped to the flash.
    let base = addr / SECTOR * SECTOR
    let lo = max(base - SECTOR, 0), hi = min(base + 2 * SECTOR, FLASH_SIZE)
    let before = try readFlash(lo, hi - lo)
    guard try readFlash(lo, hi - lo) == before else { die("two reads before programming disagree") }
    print("before:"); printDiffs(before, at: lo, backup, "dump-a")
    let old = before[addr - lo]
    print(String(format: "target %@: live %02X -> %02X", hex(addr), old, value))
    guard old & value == value else { die("needs a 0->1 bit change, which requires an erase") }
    guard old != value else { die("byte already holds that value; nothing to program") }

    for s in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGPIPE] { signal(s, SIG_IGN) }

    // Engine opcodes (awto ENGINE_OPS): WREN, EWSR, READ, FAST_READ, PP, RDSR. 0x71 = program length - 1.
    for (r, v): (UInt8, UInt8) in [(0x62, 0x06), (0x63, 0x50), (0x6A, 0x03), (0x6B, 0x0B), (0x6D, 0x02), (0x6E, 0x05), (0x71, 0x00)] {
        try write(r, v)
    }
    guard try read(0x71) == 0 else { die("program length register 0x71 did not read back 0. Nothing programmed.") }
    _ = try spi(type: 1, op: 0x06)                        // WREN
    let w = try sr1()
    guard w & 0x02 != 0, w & SR1_BP == 0 || (knownNone && w & SR1_BP == s1 & SR1_BP) else { die(String(format: "WREN not effective, SR1 = 0x%02X. Nothing programmed.", w)) }
    let want = [UInt8((addr >> 16) & 0xFF), UInt8((addr >> 8) & 0xFF), UInt8(addr & 0xFF)]
    for i in 0..<3 { try write(0x64 + UInt8(i), want[i]) }
    guard try (0..<3).map({ try read(0x64 + UInt8($0)) }) == want else { die("address registers did not read back. Nothing programmed.") }
    try poll("page buffer ready") { try read(0x6F) & 0x10 != 0 }

    // From here the flash may change. No retries; whatever happens, read back and report.
    var programError: String?
    do {
        try writeOnce(0x70, value)
        let v = try read(0x6F)
        try writeOnce(0x6F, v | 0x20)                     // start page program (PP 0x02, 1 byte)
        try poll("program engine") { try read(0x6F) & 0x20 == 0 }
        try poll("flash WIP") { try sr1() & 0x01 == 0 }
    } catch {
        programError = (error as? BusError)?.what ?? "\(error)"
        print("program step failed: \(programError!)")
    }

    guard let after = try? readFlash(lo, hi - lo) else {
        print("FAIL: cannot read back; flash state UNKNOWN. Power-cycle, then check with readback / dump."); exit(5)
    }
    print(String(format: "readback %@ = %02X (wanted %02X, was %02X)", hex(addr), after[addr - lo], value, old))
    print("after:"); printDiffs(after, at: lo, backup, "dump-a")
    var expected = before
    expected[addr - lo] = value
    let wrong = after.indices.filter { after[$0] != expected[$0] }
    for i in wrong { print(String(format: "  UNEXPECTED %@  before %02X  now %02X", hex(lo + i), before[i], after[i])) }
    if wrong.isEmpty && programError == nil {
        print("OK: only \(hex(addr)) changed in \(hex(lo))..\(hex(hi - 1)). Power-cycle the monitor."); exit(0)
    }
    print("FAIL: \(wrong.count) bytes differ from the expected result. Do not run anything else that writes.")
    exit(5)
}

func flashMode(_ mode: String, _ args: [String]) throws -> Never {
    // Everything that can be refused offline is refused before the monitor is halted.
    var it = io_iterator_t(), externals = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)
    while case let s = IOIteratorNext(it), s != 0 {
        let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if loc == "External" { externals += 1 }
    }
    guard externals == 1 else { die("need exactly one external display, found \(externals)") }

    switch mode {
    case "status":
        guard args.count == 2 else { die("usage: rtd-isp status") }
        _ = try openFlash()

    case "readback":
        guard args.count == 4, let addr = parseHex(args[2]), let len = parseHex(args[3]) ?? Int(args[3]),
              addr >= 0, len > 0, addr < FLASH_SIZE, len <= FLASH_SIZE - addr else {
            die("usage: rtd-isp readback <0xaddr> <len>, inside 1 MiB")
        }
        let backup = loadBackup()
        _ = try openFlash()
        let data = try readFlash(addr, len)
        for row in stride(from: 0, to: len, by: 16) {
            print(hex(addr + row) + "  " + data[row..<min(row + 16, len)].map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        printDiffs(data, at: addr, backup, "dump-a")

    case "sector-dry":
        guard args.count == 4, let base = parseHex(args[3]), base >= 0, base < FLASH_SIZE, base % SECTOR == 0 else {
            die("usage: rtd-isp sector-dry <image.bin> <0xsector_addr>, 4 KiB aligned, below 0x100000")
        }
        guard let i = FileManager.default.contents(atPath: args[2]), i.count == FLASH_SIZE else { die("image missing or not 1 MiB") }
        let image = [UInt8](i), backup = loadBackup()
        let outside = (0..<FLASH_SIZE).filter { image[$0] != backup[$0] && !(base..<base + SECTOR).contains($0) }
        guard outside.isEmpty else { die("image differs from backup outside the sector: \(outside.count) bytes, first \(hex(outside[0]))") }
        guard image != backup else { die("image does not differ from backup in sector \(hex(base))") }
        _ = try openFlash()
        let live = try readFlash(base, SECTOR)
        printDiffs(live, at: base, image, "image")
        printDiffs(live, at: base, backup, "dump-a")
        guard live == Array(backup[base..<base + SECTOR]) else { die("live sector does not equal the backup") }
        guard try readFlash(base, SECTOR) == live else { die("two reads of the live sector disagree") }
        let up = live.indices.filter { live[$0] & image[base + $0] != image[base + $0] }.count
        print("DRY RUN OK. Bytes needing a 0->1 change (not possible without erase): \(up)")

    default:  // byte-program
        guard args.count == 5, args[4] == "--i-have-a-backup", let addr = parseHex(args[2]),
              let value = parseHex(args[3]), addr >= 0, addr < FLASH_SIZE, (0...255).contains(value) else {
            die("usage: rtd-isp byte-program <0xaddr> <0xvalue> --i-have-a-backup")
        }
        guard !LIVE_DATA.contains(addr) else { die("banks 11-12 hold live calibration/settings") }
        try byteProgram(addr, UInt8(value), loadBackup())
    }
    exit(0)
}

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "regs"
do {
    if ["status", "readback", "sector-dry", "byte-program"].contains(mode) { try flashMode(mode, args) }
    guard ["regs", "jedec", "dump", "scaler"].contains(mode) else { die("unknown mode \(mode)") }
    for r: UInt8 in [0x6F, 0x60, 0x67, 0x68, 0x69] { print(String(format: "reg 0x%02X = 0x%02X", r, try read(r))) }
    if mode == "regs" { exit(0) }
    if mode == "scaler" {
        // Scaler register window (volatile, not flash): F4 <- reg, then F5 read/write. Leaves MCU halted.
        // ops: r:28  w:28=a0  bg (reset 0x6C port index, read 0x6D x4)
        try enterIsp()
        func rd(_ r: UInt8) throws -> UInt8 { try write(0xF4, r); return try read(0xF5) }
        func wr(_ r: UInt8, _ v: UInt8) throws { try write(0xF4, r); try write(0xF5, v) }
        for op in args.dropFirst(2) {
            if op == "bg" {
                let c = try rd(0x6C)
                try wr(0x6C, c & ~0x20); try wr(0x6C, c | 0x20)
                let v = try (0..<4).map { _ in try rd(0x6D) }
                try wr(0x6C, c & ~0x20)
                print("bg 0x6D port: " + v.map { String(format: "%02X", $0) }.joined(separator: " "))
            } else if op.hasPrefix("r:"), let r = UInt8(op.dropFirst(2), radix: 16) {
                print(String(format: "r 0x%02X = 0x%02X", r, try rd(r)))
            } else if op.hasPrefix("w:") {
                let p = op.dropFirst(2).split(separator: "=")
                guard p.count == 2, let r = UInt8(p[0], radix: 16), let v = UInt8(p[1], radix: 16) else { continue }
                try wr(r, v); print(String(format: "w 0x%02X <- 0x%02X, now 0x%02X", r, v, try rd(r)))
            } else if op.hasPrefix("bgset:") {
                // 8-bit R,G,B into the 10-bit port (high bytes, then low bits 0)
                let p = op.dropFirst(6).split(separator: ",").compactMap { UInt8($0, radix: 16) }
                guard p.count == 3 else { continue }
                let c = try rd(0x6C)
                try wr(0x6C, c & ~0x20); try wr(0x6C, c | 0x20)
                for b in p { try wr(0x6D, b) }; try wr(0x6D, 0x00)
                try wr(0x6C, c & ~0x20)
                print("bg set to \(p)")
            }
        }
        print("MCU left halted; power-cycle the monitor to restore")
        exit(0)
    }
    try enterIsp()
    defer { resetScaler() }
    let id = try jedec()
    print("JEDEC ID = " + id.map { String(format: "%02x", $0) }.joined(separator: " "))
    guard id[2] >= 0x10, id[2] <= 0x18 else { throw BusError(what: "implausible flash size code \(id[2])") }
    if mode == "dump", args.count > 2 { try dump(1 << Int(id[2]), URL(fileURLWithPath: args[2])) }
} catch let e as BusError {
    fputs("error: \(e.what)\n", stderr); exit(2)
}
