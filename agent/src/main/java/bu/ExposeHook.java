package bu;

import java.lang.reflect.Method;
import java.lang.reflect.Type;

/**
 * Vanilla-Lua publication of {@link BUControl}, reflection-only so the
 * agent never statically links game or Kahlua classes (version-proof;
 * any API drift ends in a logged no-bridge instead of a crash).
 *
 * Vanilla {@code exposeLikeJavaRecursively} publishes under the package
 * path ({@code bu.BUControl}), while BU Lua historically uses the global
 * {@code BUControl} that ZombieBuddy provided. Both are wired: the
 * package table first, then a top-level alias.
 */
public final class ExposeHook {

    private ExposeHook() {
    }

    public static void register() {
        try {
            Class<?> lm = Class.forName("zombie.Lua.LuaManager");
            Object exposer = lm.getField("exposer").get(null);
            Object env = lm.getField("env").get(null);
            if (exposer == null || env == null) {
                System.err.println("[BU-Agent] failed: LuaManager.exposer/env is null");
                return;
            }
            exposer.getClass().getMethod("setExposed", Class.class)
                    .invoke(exposer, BUControl.class);
            Method expose = exposer.getClass().getMethod(
                    "exposeLikeJavaRecursively", Type.class, rawTableClass());
            expose.invoke(exposer, BUControl.class, env);
            aliasTopLevel(env);
            System.out.println("[BU-Agent] exposed bu.BUControl (+BUControl alias)");
        } catch (Throwable t) {
            System.err.println("[BU-Agent] failed to expose BUControl: " + t);
        }
    }

    /** Top-level {@code BUControl} alias so existing Lua keeps working. */
    private static void aliasTopLevel(Object env) {
        try {
            Method rawget = env.getClass().getMethod("rawget", Object.class);
            Method rawset = env.getClass().getMethod("rawset", Object.class, Object.class);
            Object ns = rawget.invoke(env, "bu");
            if (ns == null) {
                return;
            }
            Object ctrl = rawget.invoke(ns, "BUControl");
            if (ctrl == null) {
                return;
            }
            rawset.invoke(env, "BUControl", ctrl);
        } catch (Throwable t) {
            System.err.println("[BU-Agent] failed to alias BUControl: " + t);
        }
    }

    private static Class<?> rawTableClass() throws ClassNotFoundException {
        return Class.forName("se.krka.kahlua.vm.KahluaTable");
    }
}
