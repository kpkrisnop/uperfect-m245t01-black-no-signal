// postScript: arg0 = bank. Writes out/bankN.asm and out/bankN.c
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.listing.*;
import java.io.PrintWriter;

public class Dump extends GhidraScript {
    public void run() throws Exception {
        String base = getSourceFile().getParentFile().getAbsolutePath() + "/out/bank" + getScriptArgs()[0];
        try (PrintWriter p = new PrintWriter(base + ".asm")) {
            for (Instruction i : currentProgram.getListing().getInstructions(true)) {
                Function f = getFunctionContaining(i.getAddress());
                if (f != null && f.getEntryPoint().equals(i.getAddress())) p.println("\n== " + f.getName() + " @" + i.getAddress().getOffset());
                StringBuilder h = new StringBuilder();
                for (byte b : i.getBytes()) h.append(String.format("%02x", b & 0xff));
                p.println(String.format("%04X %-6s %s", i.getAddress().getOffset(), h, i));
            }
        }
        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);
        try (PrintWriter p = new PrintWriter(base + ".c")) {
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                DecompileResults r = d.decompileFunction(f, 60, monitor);
                p.println(String.format("\n// ==== %s @%04X", f.getName(), f.getEntryPoint().getOffset()));
                p.println(r.decompileCompleted() ? r.getDecompiledFunction().getC() : "// FAIL " + r.getErrorMessage());
            }
        }
    }
}
