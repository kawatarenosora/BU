package bu;

import java.lang.instrument.Instrumentation;
import java.util.Properties;
import net.bytebuddy.agent.builder.AgentBuilder;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.description.type.TypeDescription;
import net.bytebuddy.dynamic.DynamicType;
import net.bytebuddy.matcher.ElementMatchers;
import net.bytebuddy.utility.JavaModule;

/**
 * BU javaagent (ZombieBuddy-free).
 * Publishes bu.BUControl to vanilla Lua by hooking the single choke point
 * {@code zombie.Lua.LuaManager$Exposer.exposeAll} exit. No game-class
 * transformation besides this one hook; backup logic itself is pure
 * java.nio and version-independent (lenient gate, see launcher request).
 * Any failure logs and lets the game continue without the bridge.
 */
public class Agent {

    static final String REV = readRev();

    public static void premain(String args, Instrumentation inst) {
        if (args == null) {
            args = "";
        }
        boolean en = true;
        if (args.contains("enabled=false") || args.contains("disabled")) {
            en = false;
        }
        if ("false".equalsIgnoreCase(System.getProperty("bu.enabled", "true"))) {
            en = false;
        }
        System.out.println("[BU-Agent] loaded rev=" + REV + " enabled=" + en
                + (args.isEmpty() ? "" : " args=" + args));
        if (!en) {
            return;
        }
        try {
            new AgentBuilder.Default()
                    .with(new LogListener())
                    .type(ElementMatchers.named("zombie.Lua.LuaManager$Exposer"))
                    .transform((b, td, cl, m, pd) -> b.visit(
                            Advice.to(ExposeAdvice.class).on(
                                    ElementMatchers.named("exposeAll"))))
                    .installOn(inst);
            System.out.println("[BU-Agent] transformer registered targets=LuaManager$Exposer");
        } catch (Throwable t) {
            System.err.println("[BU-Agent] failed to register transformer: " + t);
        }
    }

    static final class LogListener extends AgentBuilder.Listener.Adapter {
        @Override
        public void onTransformation(TypeDescription td, ClassLoader cl,
                JavaModule m, boolean loaded, DynamicType dt) {
            System.out.println("[BU-Agent] Transformed " + td.getName());
        }

        @Override
        public void onError(String name, ClassLoader cl,
                JavaModule m, boolean loaded, Throwable t) {
            System.err.println("[BU-Agent] failed " + name + ": " + t);
        }
    }

    static String readRev() {
        try {
            Properties p = new Properties();
            try (java.io.InputStream in =
                         Agent.class.getResourceAsStream("/bu/build-info.properties")) {
                if (in == null) {
                    return "unversioned";
                }
                p.load(in);
            }
            String r = p.getProperty("revision", "unversioned");
            return r != null ? r.trim() : "unversioned";
        } catch (Throwable t) {
            return "unversioned";
        }
    }
}
