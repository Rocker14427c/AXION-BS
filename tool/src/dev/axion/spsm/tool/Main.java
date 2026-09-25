package dev.axion.spsm.tool;

import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.ResultReceiver;

import java.io.ByteArrayOutputStream;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.TimeUnit;

/**
 * SPSM's batch tool: ONE JVM for a whole batch of service calls.
 *
 * The census of 2026-09-25 (a full daily round, every service command
 * shimmed) counted 6,354 calls in 488 seconds - and the shells behind them
 * are the cost: every `am`/`pm`/`cmd` is a process, a linker pass and, for
 * the JVM wrappers, a whole runtime start, for one binder transaction each.
 * Under the power-save governor the fan of them averaged 60-480ms a call.
 *
 * This tool does the same transactions WITHOUT the processes: it runs as uid
 * 2000 through app_process - the same identity and classpath the platform's
 * own `pm`/`settings` wrappers run under - and hands each line of the batch
 * to the service's shellCommand entry point in-process. That entry point is
 * exactly what the `cmd` binary calls from the outside: same permissions,
 * same argument parsing, same output, same result codes, only without a
 * fork, an exec and a runtime start per call.
 *
 * Protocol (verb: shellbatch)
 *   stdin, one operation per line, tab separated:
 *       SERVICE<TAB>ARG<TAB>ARG...          e.g. activity<TAB>get-standby-bucket<TAB>com.pkg
 *   stdout, one frame per line, in order:
 *       ###<TAB>index<TAB>rc
 *       <the command's own output, verbatim>
 *       ###<TAB>END
 *   rc is the service's own result code (what `cmd` would exit with);
 *   negative codes are the tool's own: -1 service not found, -2 call failed,
 *   -3 timed out. A frame always appears for every input line, so the caller
 *   can tell a dead tool (no frames, nonzero exit) from a dead service
 *   (frames with error codes) and fall back accordingly.
 *
 * Deliberately NO interpretation of any service's output here: the shell
 * side parses exactly the bytes the plain command would have printed, so the
 * tool can never drift from the contract the module was written against.
 */
public final class Main {

    /** Per-operation ceiling. A service that hangs must not take the batch,
     *  the caller, and the mode's journal with it. */
    private static final long OP_TIMEOUT_S = 30;

    private static Method sShellCommand;      // IBinder.shellCommand(...)
    private static Method sGetService;        // ServiceManager.getService(String)
    private static FileDescriptor sDevNull;

    public static void main(String[] argv) throws Exception {
        if (argv.length == 0) {
            // No verb: the usage answer, with status 2 - the same proof of
            // life the native helpers give publish_native().
            System.err.println("usage: spsm-tool shellbatch   (tab-separated ops on stdin)");
            System.exit(2);
            return;
        }
        if ("shellbatch".equals(argv[0])) {
            // The batch may arrive as a file path instead of stdin: the module
            // starts this tool through `su 2000 -c`, and a file is one less
            // thing a su implementation can fail to forward.
            shellbatch(argv.length > 1 ? argv[1] : null);
            return;
        }
        System.err.println("unknown verb: " + argv[0]);
        System.exit(2);
    }

    private static void shellbatch(String sourceFile) throws Exception {
        initReflection();
        InputStream src = (sourceFile != null)
                ? new FileInputStream(sourceFile)
                : System.in;
        BufferedReader in = new BufferedReader(new InputStreamReader(src, "UTF-8"));
        PrintStream out = new PrintStream(System.out, false, "UTF-8");
        String line;
        int index = 0;
        while ((line = in.readLine()) != null) {
            if (line.length() == 0) continue;
            String[] parts = line.split("\t", -1);
            String service = parts[0];
            String[] args = Arrays.copyOfRange(parts, 1, parts.length);
            int rc;
            String output;
            try {
                Object binder = sGetService.invoke(null, service);
                if (binder == null) {
                    rc = -1;
                    output = "service not found: " + service + "\n";
                } else {
                    String[] r = runShellCommand((IBinder) binder, args);
                    rc = Integer.parseInt(r[0]);
                    output = r[1];
                }
            } catch (Throwable t) {
                rc = -2;
                output = "tool error: " + t + "\n";
            }
            out.print("###\t" + index + "\t" + rc + "\n");
            out.print(output);
            if (!output.endsWith("\n")) out.print('\n');
            out.print("###\tEND\n");
            index++;
        }
        out.flush();
    }

    /** One in-process shellCommand transaction; returns {rc, output}. */
    private static String[] runShellCommand(IBinder binder, String[] args) throws Exception {
        ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
        ParcelFileDescriptor readSide = pipe[0];
        ParcelFileDescriptor writeSide = pipe[1];
        final SynchronousQueue<Integer> result = new SynchronousQueue<Integer>();
        ResultReceiver receiver = new ResultReceiver(null) {
            @Override
            protected void onReceiveResult(int resultCode, android.os.Bundle resultData) {
                result.offer(Integer.valueOf(resultCode));
            }
        };
        int rc;
        String output;
        try {
            // out and err are the same pipe: the shell side wants the
            // command's answer as one text, exactly like `cmd ... 2>&1`.
            sShellCommand.invoke(binder,
                    sDevNull,
                    writeSide.getFileDescriptor(),
                    writeSide.getFileDescriptor(),
                    args,
                    null,
                    receiver);
            // Our copy of the write end must be closed, or the read end never
            // sees EOF: the service got its own duplicate of the descriptor.
            writeSide.close();
            output = readAll(new FileInputStream(readSide.getFileDescriptor()));
            Integer delivered = result.poll(OP_TIMEOUT_S, TimeUnit.SECONDS);
            rc = (delivered == null) ? -3 : delivered.intValue();
        } finally {
            try { writeSide.close(); } catch (Throwable ignored) { }
            try { readSide.close(); } catch (Throwable ignored) { }
        }
        return new String[] { String.valueOf(rc), output };
    }

    private static String readAll(InputStream fdStream) throws Exception {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int n;
        while ((n = fdStream.read(chunk)) > 0) buf.write(chunk, 0, n);
        return new String(buf.toByteArray(), "UTF-8");
    }

    private static void initReflection() throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        sGetService = sm.getMethod("getService", String.class);

        // IBinder.shellCommand(FileDescriptor in, FileDescriptor out,
        //     FileDescriptor err, String[] args, IShellCallback callback,
        //     ResultReceiver resultReceiver)
        // Found by name rather than by signature: IShellCallback is not on
        // the public SDK's compile classpath, and its exact type must not
        // matter - null is passed for it anyway.
        Method found = null;
        for (Method m : IBinder.class.getMethods()) {
            if ("shellCommand".equals(m.getName())) { found = m; break; }
        }
        if (found == null) {
            // On some builds it is declared on the concrete proxy class only.
            Class<?> proxy = Class.forName("android.os.BinderProxy");
            for (Method m : proxy.getDeclaredMethods()) {
                if ("shellCommand".equals(m.getName())) {
                    m.setAccessible(true);
                    found = m;
                    break;
                }
            }
        }
        if (found == null) throw new IllegalStateException("IBinder.shellCommand not available");
        sShellCommand = found;

        sDevNull = new FileInputStream("/dev/null").getFD();
    }
}
