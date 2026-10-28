package bu;

import java.io.InputStream;
import java.util.Properties;

/**
 * BU Java-mod entry point (ZombieBuddy edition).
 *
 * ZombieBuddy loads the mod jar declared in mod.info (javaJarFile +
 * javaPkgName=bu) and invokes this Main class, on both ZB 2.x and 3.x.
 * No ByteBuddy and no -javaagent line anywhere: publication of
 * {@link BUControl} to Lua is arranged here (and redundantly by the
 * {@code @Exposer.LuaClass} annotation on BUControl, which ZB 3.x picks up
 * automatically when scanning the javaPkgName package).
 *
 * All ZombieBuddy API calls go through reflection so the jar never becomes
 * dead weight when ZB moves an API; a missing method is a logged fallback,
 * not a crash. Backup logic itself lives in {@link BUControl} (pure
 * java.nio, game-version independent).
 */
public class Main {

    public static void main(String[] args) {
        System.out.println("[BU] mod jar loaded rev=" + rev()
                + " (ZombieBuddy edition, bu.BUControl)");
        if (expose()) {
            System.out.println("[BU] bu.BUControl exposure requested");
        } else {
            System.err.println("[BU] exposure request failed; ZB's own "
                    + "@Exposer.LuaClass scanning is the remaining path");
        }
    }

    /**
     * Requests exposure in a version-tolerant order:
     * {@code exposeClass(Class)} (ZB 2.3+/3.x, current) then
     * {@code exposeClassToLua(Class)} (older ZB 2.x). Both calls are
     * idempotent on the ZB side and deferred by ZB itself (exposure happens
     * after the game's exposeAll pass), so this is safe however early the
     * mod jar is loaded.
     */
    private static boolean expose() {
        try {
            Class<?> ex = Class.forName("me.zed_0xff.zombie_buddy.Exposer");
            try {
                ex.getMethod("exposeClass", Class.class)
                        .invoke(null, (Object) BUControl.class);
                System.out.println("[BU] exposed via Exposer.exposeClass");
                return true;
            } catch (NoSuchMethodException older) {
                ex.getMethod("exposeClassToLua", Class.class)
                        .invoke(null, (Object) BUControl.class);
                System.out.println("[BU] exposed via Exposer.exposeClassToLua (legacy ZB 2.x API)");
                return true;
            }
        } catch (Throwable t) {
            System.err.println("[BU] could not invoke ZB Exposer: " + t);
            return false;
        }
    }

    /** Shipped revision tag from bu/build-info.properties (display only). */
    static String rev() {
        try (InputStream in = Main.class.getResourceAsStream("/bu/build-info.properties")) {
            if (in == null) {
                return "unversioned";
            }
            Properties p = new Properties();
            p.load(in);
            String r = p.getProperty("revision");
            return r != null && !r.trim().isEmpty() ? r.trim() : "unversioned";
        } catch (Throwable t) {
            return "unversioned";
        }
    }
}
