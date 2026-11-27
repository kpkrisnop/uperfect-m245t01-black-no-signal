// preScript: arg0 = bank. Stubs trampolines (in Ghidra memory only) and seeds functions.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.SourceType;

public class Setup extends GhidraScript {
    Address a(int x) { return currentProgram.getAddressFactory().getAddressSpace("CODE").getAddress(x); }
    int u(int x) throws Exception { return getByte(a(x)) & 0xff; }
    public void run() throws Exception {
        int bank = Integer.parseInt(getScriptArgs()[0]);
        // trampolines: 90 hh ll 02 02 ss ; target bank = (switcher - 0x22F) / 0x12
        java.util.List<int[]> tr = new java.util.ArrayList<>();
        for (int t = 0x300; t < 0x1500; t++) {
            if (u(t) != 0x90 || u(t + 3) != 0x02 || u(t + 4) != 0x02) continue;
            int sw = 0x200 + u(t + 5), tgt = (u(t + 1) << 8) | u(t + 2);
            if (sw < 0x22F || (sw - 0x22F) % 0x12 != 0) continue;
            int tb = (sw - 0x22F) / 0x12;
            setByte(a(t), (byte) 0x22); // RET (all patched before any disassembly)
            tr.add(new int[] {t, tb, tgt});
            t += 5;
        }
        for (int[] e : tr) {
            int t = e[0], tb = e[1], tgt = e[2];
            String n = String.format("b%d_%04X", tb, tgt);
            disassemble(a(t));
            createFunction(a(t), "T_" + n);
            println(String.format("TRAMP %04X %d %04X", t, tb, tgt));
            if (tb == bank) { disassemble(a(tgt)); createFunction(a(tgt), n); }
        }
        for (int v : new int[] {0, 3, 0xB, 0x13, 0x1B, 0x23, 0x2B}) { disassemble(a(v)); createFunction(a(v), null); }
        // JMP @A+DPTR followed by a table of LJMPs (auto-analysis misses these)
        for (int p = 0x2726; p < 0xFFF0; p++) {
            if (u(p) != 0x73 || u(p + 1) != 0x02 || u(p + 4) != 0x02) continue;
            for (int q = p + 1; q < 0xFFF0 && u(q) == 0x02; q += 3) disassemble(a(q));
        }
        // Keil switch tables (?C?CCASE 0x198D: addr16,val8 ; ?C?ICASE 0x19B3: addr16,val16 ; end 0000,default)
        for (int p = 0x2726; p < 0xFFF0; p++) {
            if (u(p) != 0x12 || u(p + 1) != 0x19 || (u(p + 2) != 0x8D && u(p + 2) != 0xB3)) continue;
            int size = u(p + 2) == 0x8D ? 3 : 4, q = p + 3;
            while (q < 0xFFF0 && ((u(q) << 8) | u(q + 1)) != 0) {
                int tgt = (u(q) << 8) | u(q + 1);
                disassemble(a(tgt));
                println(String.format("CASE sw=%04X val=%s -> %04X", p,
                    size == 3 ? String.format("%02X", u(q + 2)) : String.format("%02X%02X", u(q + 2), u(q + 3)), tgt));
                q += size;
            }
            int def = (u(q + 2) << 8) | u(q + 3);
            disassemble(a(def));
            println(String.format("CASE sw=%04X default -> %04X", p, def));
        }
    }
}
