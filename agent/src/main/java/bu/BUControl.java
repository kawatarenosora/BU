package bu;

import java.io.IOException;
import java.nio.file.AccessDeniedException;
import java.nio.file.DirectoryStream;
import java.nio.file.FileSystemException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * BU backup bridge (exposed to Lua as bu.BUControl, plus a legacy top-level
 * BUControl alias that the Lua side self-installs).
 * All methods are static, pcall-safe and return plain Strings
 * (Kahlua-friendly: no overloaded Java objects leak to Lua).
 *
 * Layout: the backup root (default {@code <user.home>/Zomboid/BU}, inside
 * the game's save root) holds one fixed slot per save:
 * {@code <mode>__<saveName>/}. No timestamp generations.
 * Every write goes tmp -&gt; verify -&gt; swap so a failed attempt never
 * destroys the previous good backup.
 *
 * Dual edition: publication to Lua comes from one of two sources, exactly
 * one at a time - the -javaagent hook (bu.Agent, sets the bu.javaagent
 * property) or the ZombieBuddy mod load (bu.Main, reflective
 * Exposer.exposeClass call). No @Exposer.LuaClass annotation on purpose:
 * ZB 3.x's automatic package scan would bypass the single-bridge guard.
 */
public class BUControl {
    public static final String VERSION = "0.6.0";
    /** Max bytes to read from an exception message (keep Lua strings small). */
    private static final int MAX_MSG = 220;

    public static String version() {
        return VERSION;
    }

    /** Blocking sleep for retry pacing on screens without tick events. */
    public static String sleepMs(long ms) {
        try {
            if (ms < 0) {
                ms = 0;
            }
            if (ms > 30000) {
                ms = 30000;
            }
            Thread.sleep(ms);
            return "OK";
        } catch (Throwable t) {
            return "ERR_IO|" + shortMsg(t);
        }
    }

    /**
     * Default backup root: {@code <user.home>/Zomboid/BU}.
     *
     * <p>Note this is <em>inside</em> the game's save root (it sits next to
     * {@code Sandbox/} and {@code Multiplayer/}), not outside it. Deleting a
     * save in-game does not touch it, but wiping the whole {@code Zomboid}
     * folder does. Resolves per platform: {@code C:\Users\<you>\Zomboid\BU}
     * on Windows, {@code /Users/<you>/Zomboid/BU} on macOS,
     * {@code /home/<you>/Zomboid/BU} on Linux.
     */
    public static String defaultRoot() {
        try {
            String home = System.getProperty("user.home", ".");
            return Paths.get(home, "Zomboid", "BU").toString();
        } catch (Throwable t) {
            return "ERR_IO|" + shortMsg(t);
        }
    }

    /** Full slot path for one save: root/mode__name (sanitized). */
    public static String slotFor(String rootAbs, String mode, String name) {
        try {
            String slot = sanitize(mode) + "__" + sanitize(name);
            return Paths.get(rootAbs, slot).toString();
        } catch (Throwable t) {
            return "ERR_IO|" + shortMsg(t);
        }
    }

    /**
     * Copy src dir to dest dir (single slot, overwrite).
     * Returns OK|files=N|bytes=B, ERR_RETRY|detail (transient, safe to
     * retry), ERR_NOSRC|detail, ERR_VERIFY|detail, ERR_IO|detail.
     */
    public static String backupTo(String srcAbs, String destAbs) {
        if (srcAbs == null || srcAbs.isEmpty() || destAbs == null || destAbs.isEmpty()) {
            return "ERR_IO|empty path";
        }
        try {
            Path src = Paths.get(srcAbs);
            Path dest = Paths.get(destAbs);
            if (!Files.isDirectory(src)) {
                return "ERR_NOSRC|not a directory: " + srcAbs;
            }
            if (parentOf(dest) != null) {
                Files.createDirectories(parentOf(dest));
            }
            Path tmp = Paths.get(destAbs + "_tmp");
            deleteTree(tmp);
            CopyStats st = copyTree(src, tmp);
            String bad = verifyTree(tmp);
            if (bad != null) {
                deleteTree(tmp);
                return "ERR_VERIFY|" + bad;
            }
            deleteTree(dest);
            try {
                Files.move(tmp, dest, StandardCopyOption.ATOMIC_MOVE);
            } catch (Throwable moveFail) {
                try {
                    Files.move(tmp, dest);
                } catch (Throwable moveFail2) {
                    copyTree(tmp, dest);
                    deleteTree(tmp);
                }
            }
            System.out.println("[BU-Java] backup OK src=" + srcAbs + " files=" + st.files + " bytes=" + st.bytes);
            return "OK|files=" + st.files + "|bytes=" + st.bytes;
        } catch (AccessDeniedException ade) {
            return "ERR_RETRY|access denied: " + shortMsg(ade);
        } catch (FileSystemException fse) {
            String m = shortMsg(fse);
            if (isLockLike(m)) {
                return "ERR_RETRY|locked: " + m;
            }
            return "ERR_IO|" + m;
        } catch (Throwable t) {
            return "ERR_IO|" + shortMsg(t);
        }
    }

    /** Restore is the same primitive in reverse: backup dir -&gt; live save dir. */
    public static String restoreBackup(String backupAbs, String saveAbs) {
        return backupTo(backupAbs, saveAbs);
    }

    /**
     * List slots under root. Returns lines "slot|mtimeMs|files|bytes"
     * sorted, "EMPTY" when none, or "ERR_IO|detail".
     * "_tmp" leftovers are skipped (never offered for restore).
     */
    public static String listBackups(String rootAbs) {
        try {
            Path root = Paths.get(rootAbs);
            if (!Files.isDirectory(root)) {
                return "EMPTY";
            }
            List<String> out = new ArrayList<String>();
            try (DirectoryStream<Path> ds = Files.newDirectoryStream(root)) {
                for (Path p : ds) {
                    String n = p.getFileName().toString();
                    if (!Files.isDirectory(p) || n.endsWith("_tmp")) {
                        continue;
                    }
                    long mtime = 0;
                    long bytes = 0;
                    long files = 0;
                    try {
                        mtime = Files.getLastModifiedTime(p).toMillis();
                    } catch (Throwable ignored) {
                    }
                    try {
                        CopyStats st = statTree(p);
                        bytes = st.bytes;
                        files = st.files;
                    } catch (Throwable ignored) {
                    }
                    out.add(n + "|" + mtime + "|" + files + "|" + bytes);
                }
            }
            if (out.isEmpty()) {
                return "EMPTY";
            }
            Collections.sort(out);
            StringBuilder sb = new StringBuilder();
            for (String s : out) {
                sb.append(s).append('\n');
            }
            return sb.toString().trim();
        } catch (Throwable t) {
            return "ERR_IO|" + shortMsg(t);
        }
    }

    // ---------- helpers ----------

    private static Path parentOf(Path p) {
        try {
            return p.getParent();
        } catch (Throwable t) {
            return null;
        }
    }

    private static String sanitize(String s) {
        if (s == null) {
            return "_";
        }
        String r = s.replaceAll("[^A-Za-z0-9-_ ]", "_").trim();
        if (r.isEmpty()) {
            return "_";
        }
        if (r.equals(".") || r.equals("..")) {
            return "_";
        }
        return r;
    }

    private static boolean isLockLike(String m) {
        if (m == null) {
            return false;
        }
        String l = m.toLowerCase();
        return l.contains("being used by another process")
            || l.contains("access is denied")
            || l.contains("lock")
            || l.contains("sharing violation");
    }

    private static String shortMsg(Throwable t) {
        String m;
        try {
            m = String.valueOf(t.getMessage());
            if (m == null || m.equals("null") || m.isEmpty()) {
                m = String.valueOf(t);
            }
        } catch (Throwable ignored) {
            m = "unknown error";
        }
        m = m.replace('\n', ' ').replace('\r', ' ');
        if (m.length() > MAX_MSG) {
            m = m.substring(0, MAX_MSG);
        }
        return m;
    }

    private static final class CopyStats {
        long files;
        long bytes;
    }

    private static CopyStats copyTree(Path src, Path dest) throws IOException {
        final CopyStats st = new CopyStats();
        final Path s = src;
        final Path d = dest;
        Files.walkFileTree(s, new java.nio.file.SimpleFileVisitor<Path>() {
            @Override
            public java.nio.file.FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes a) throws IOException {
                Path rel = s.relativize(dir);
                Path target = rel.toString().isEmpty() ? d : d.resolve(rel.toString());
                Files.createDirectories(target);
                return java.nio.file.FileVisitResult.CONTINUE;
            }

            @Override
            public java.nio.file.FileVisitResult visitFile(Path file, BasicFileAttributes a) throws IOException {
                Path target = d.resolve(s.relativize(file).toString());
                if (target.getParent() != null) {
                    Files.createDirectories(target.getParent());
                }
                Files.copy(file, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.COPY_ATTRIBUTES);
                st.files++;
                try {
                    st.bytes += Files.size(target);
                } catch (Throwable ignored) {
                }
                return java.nio.file.FileVisitResult.CONTINUE;
            }
        });
        return st;
    }

    private static CopyStats statTree(Path root) throws IOException {
        final CopyStats st = new CopyStats();
        Files.walkFileTree(root, new java.nio.file.SimpleFileVisitor<Path>() {
            @Override
            public java.nio.file.FileVisitResult visitFile(Path file, BasicFileAttributes a) {
                st.files++;
                try {
                    st.bytes += a.size();
                } catch (Throwable ignored) {
                }
                return java.nio.file.FileVisitResult.CONTINUE;
            }
        });
        return st;
    }

    private static void deleteTree(Path root) throws IOException {
        if (root == null || !Files.exists(root)) {
            return;
        }
        Files.walkFileTree(root, new java.nio.file.SimpleFileVisitor<Path>() {
            @Override
            public java.nio.file.FileVisitResult visitFile(Path file, BasicFileAttributes a) throws IOException {
                Files.deleteIfExists(file);
                return java.nio.file.FileVisitResult.CONTINUE;
            }

            @Override
            public java.nio.file.FileVisitResult postVisitDirectory(Path dir, IOException e) throws IOException {
                Files.deleteIfExists(dir);
                return java.nio.file.FileVisitResult.CONTINUE;
            }
        });
    }

    /** Light verification: non-empty copy. Returns null when OK. */
    private static String verifyTree(Path root) {
        try {
            if (!Files.isDirectory(root)) {
                return "copy missing";
            }
            CopyStats st = statTree(root);
            if (st.files <= 0 || st.bytes <= 0) {
                return "empty copy files=" + st.files + " bytes=" + st.bytes;
            }
            return null;
        } catch (Throwable t) {
            return "verify failed: " + shortMsg(t);
        }
    }
}
