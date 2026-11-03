// 让本地 Ctrl+C / Ctrl+V 直接和远端 Chrome 互通。noVNC 自身只有侧边剪贴板面板：
// 本地按 Ctrl+V 只会把按键发到远端，粘贴出来的是远端剪贴板里的旧内容。
// VNC 协议只能传文字，图片和文件传不了。
import UI from "./app/ui.js";
import KeyTable from "./core/input/keysym.js";

const isMac = /Mac|iPhone|iPad/.test(navigator.platform);
const MAX_PASTE_BYTES = 10 * 1024 * 1024;  // 与 svc-xvnc.sh 的 -MaxCutText 保持一致
const COPY_INTENT_MS = 3000;

let lastCopyIntent = 0;
const onRemoteScreen = e => e.target instanceof HTMLCanvasElement;

window.addEventListener("keydown", e => {
    if (!onRemoteScreen(e)) return;
    if ((isMac ? e.metaKey : e.ctrlKey) && !e.altKey && e.code === "KeyV") {
        // 不交给 noVNC，让浏览器按默认行为触发 paste 事件（不需要权限，HTTP 下也可用）
        e.stopPropagation();
    } else if ((e.ctrlKey || e.metaKey) && (e.code === "KeyC" || e.code === "KeyX")) {
        lastCopyIntent = Date.now();
    }
}, true);

// 远端右键菜单里的“复制”也算用户操作
window.addEventListener("pointerup", () => { lastCopyIntent = Date.now(); }, true);

document.addEventListener("paste", e => {
    if (!onRemoteScreen(e) || !UI.rfb) return;
    e.preventDefault();

    const text = e.clipboardData.getData("text/plain");
    // 这两种情况都不发按键，否则远端会粘贴出旧内容
    if (!text) {
        UI.showStatus("只能粘贴文字：图片和文件无法通过剪贴板传到远端", "warn", 5000);
        return;
    }
    if (new Blob([text]).size > MAX_PASTE_BYTES) {
        UI.showStatus("内容超过 10MB，无法粘贴", "warn", 5000);
        return;
    }

    UI.rfb.clipboardPasteFrom(text);
    if (isMac) {  // 本地是 Cmd+V，远端需要 Ctrl+V
        UI.rfb.sendKey(KeyTable.XK_Super_L, "MetaLeft", false);
        UI.rfb.sendKey(KeyTable.XK_Control_L, "ControlLeft", true);
        UI.rfb.sendKey(KeyTable.XK_v, "KeyV");
        UI.rfb.sendKey(KeyTable.XK_Control_L, "ControlLeft", false);
    } else {  // Ctrl 已经由 noVNC 发到远端并保持按下，这里只需补上 V
        UI.rfb.sendKey(KeyTable.XK_v, "KeyV");
    }
});

// HTTP 地址上没有 navigator.clipboard，退回 execCommand（依赖刚才那次按键/点击的用户操作）
function copyWithExecCommand(text) {
    const previous = document.activeElement;
    const box = document.createElement("textarea");
    box.value = text;
    box.style.cssText = "position:fixed;top:0;left:0;opacity:0";
    document.body.append(box);
    box.select();
    document.execCommand("copy");
    box.remove();
    previous?.focus?.();
}

async function writeLocalClipboard(text) {
    try {
        await navigator.clipboard.writeText(text);
    } catch {
        copyWithExecCommand(text);
    }
}

// 只有用户刚操作过才写本地剪贴板，防止远端网页在后台改写你电脑的剪贴板。
// 没有写入时，内容仍然会显示在 noVNC 的剪贴板面板里。
const showInPanel = UI.clipboardReceive;
UI.clipboardReceive = e => {
    showInPanel(e);
    if (Date.now() - lastCopyIntent <= COPY_INTENT_MS) writeLocalClipboard(e.detail.text);
};
