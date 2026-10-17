package dev.chirp.smoke;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.HandlerThread;
import android.util.Xml;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.io.FileOutputStream;
import org.xmlpull.v1.XmlSerializer;

/** Shell-only UiAutomator probe. No application permission or release code is added. */
public final class UiHierarchy {
    public static void main(String[] args) throws Exception {
        android.os.Looper.prepareMainLooper();
        HandlerThread thread = new HandlerThread("chirp-ui-probe");
        thread.start();
        UiAutomation automation = null;
        try {
            // These shell APIs are hidden in android.jar, just as in Android's uiautomator CLI.
            Object connection = Class.forName("android.app.UiAutomationConnection").getConstructor().newInstance();
            automation = (UiAutomation) UiAutomation.class.getConstructor(android.os.Looper.class,
                Class.forName("android.app.IUiAutomationConnection")).newInstance(thread.getLooper(), connection);
            UiAutomation.class.getMethod("connect", int.class).invoke(automation, 1); // preserve TalkBack
            AccessibilityServiceInfo info = automation.getServiceInfo();
            info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            automation.setServiceInfo(info);
            if (args.length == 3 && args[0].equals("tap")) {
                long now = android.os.SystemClock.uptimeMillis();
                float x = Float.parseFloat(args[1]), y = Float.parseFloat(args[2]);
                for (int action : new int[]{android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP}) {
                    android.view.MotionEvent event = android.view.MotionEvent.obtain(now, android.os.SystemClock.uptimeMillis(), action, x, y, 0);
                    event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
                    automation.injectInputEvent(event, true);
                    event.recycle();
                }
            }
            if (args.length == 2 && (args[0].equals("click") || args[0].equals("long-click"))) {
                boolean found = false;
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo target = find(window.getRoot(), args[1]);
                    if (target != null) {
                        int action = args[0].equals("click") ? AccessibilityNodeInfo.ACTION_CLICK : AccessibilityNodeInfo.ACTION_LONG_CLICK;
                        if (!target.performAction(action)) throw new IllegalStateException("Accessibility action rejected");
                        found = true; break;
                    }
                }
                if (!found) throw new IllegalStateException("Accessible target missing");
            }
            try { automation.waitForIdle(250, 4000); } catch (java.util.concurrent.TimeoutException ignored) { }
            XmlSerializer xml = Xml.newSerializer();
            try (FileOutputStream output = new FileOutputStream("/sdcard/chirp-windows.xml")) {
                xml.setOutput(output, "UTF-8");
                xml.startDocument("UTF-8", true);
                xml.startTag(null, "hierarchy");
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo root = window.getRoot();
                    if (root != null) dump(xml, root);
                }
                xml.endTag(null, "hierarchy");
                xml.endDocument();
            }
        } finally {
            if (automation != null) UiAutomation.class.getMethod("disconnect").invoke(automation);
            thread.quitSafely();
        }
    }
    private static AccessibilityNodeInfo find(AccessibilityNodeInfo node, String label) {
        if (node == null || !node.isVisibleToUser()) return null;
        if (label.equals(safe(node.getText())) || safe(node.getContentDescription()).startsWith(label)) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = find(node.getChild(i), label);
            if (found != null) return found;
        }
        return null;
    }
    private static void dump(XmlSerializer xml, AccessibilityNodeInfo node) throws Exception {
        if (!node.isVisibleToUser()) return;
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        xml.startTag(null, "node");
        xml.attribute(null, "text", safe(node.getText()));
        xml.attribute(null, "content-desc", safe(node.getContentDescription()));
        xml.attribute(null, "package", safe(node.getPackageName()));
        xml.attribute(null, "class", safe(node.getClassName()));
        xml.attribute(null, "resource-id", safe(node.getViewIdResourceName()));
        xml.attribute(null, "bounds", bounds.toShortString());
        xml.attribute(null, "long-clickable", String.valueOf(node.isLongClickable()));
        xml.attribute(null, "clickable", String.valueOf(node.isClickable()));
        xml.attribute(null, "enabled", String.valueOf(node.isEnabled()));
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) dump(xml, child);
        }
        xml.endTag(null, "node");
    }
    private static String safe(CharSequence value) { return value == null ? "" : value.toString(); }
}
