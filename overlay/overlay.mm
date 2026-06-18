// CP2077 macOS overlay - Phase 2 complete: Dear ImGui in-game console with input.
//   * Renders an ImGui console onto the live game frame via a -[<cmdbuf> presentDrawable:] swizzle.
//   * Captures input via a -[NSApplication sendEvent:] swizzle (main thread) into a locked queue,
//     drained on the render thread so ALL ImGui calls stay single-threaded.
//   * Toggle with the backtick/tilde (`) key or F1. When open, input is swallowed from the game.
//   * Submitting a line writes it to /tmp/cp2077_cmd.txt (the existing Frida command channel);
//     the console tails /tmp/cp2077_out.txt for results. Fully decoupled from the Frida executor.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <string>
#include <vector>
#include <deque>
#include <mutex>
#include <atomic>
#include <dispatch/dispatch.h>
#include "imgui.h"
#include "backends/imgui_impl_metal.h"

// ---- logging ----
static void olog(const char* fmt, ...) {
    char buf[600]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    FILE* f = fopen("/tmp/cp2077_overlay.log", "a"); if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    fprintf(stderr, "[OVERLAY] %s\n", buf);
}

// ---- state ----
static IMP g_origPresent = NULL;
static IMP g_origSendEvent = NULL;
static bool g_imguiInit = false;
static unsigned long g_frame = 0;
static std::atomic<bool> g_show{false};
static std::atomic<bool> g_focusInput{false};
static std::vector<std::string> g_lines;
static char g_input[512] = {0};
static std::vector<std::string> g_history;   // submitted commands (oldest first)
static int g_historyPos = -1;                // -1 = current edit line; else index into g_history
static const char* OUT_PATH = "/tmp/cp2077_out.txt";
static const char* CMD_PATH = "/tmp/cp2077_cmd.txt";

// ---- input event queue (main thread -> render thread) ----
struct InEvent { int type; int code; bool down; unsigned ch; float x; float y; };
static std::deque<InEvent> g_queue;
static std::mutex g_qmtx;

// ---- command channel ----
static void refreshOut() {
    FILE* f = fopen(OUT_PATH, "r"); if (!f) return;
    g_lines.clear();
    char line[2048];
    while (fgets(line, sizeof(line), f)) { size_t n = strlen(line); if (n && line[n-1] == '\n') line[n-1] = 0; g_lines.push_back(line); }
    fclose(f);
    if (g_lines.size() > 400) g_lines.erase(g_lines.begin(), g_lines.end() - 400);
}
static void submitCommand(const char* c) {
    FILE* f = fopen(CMD_PATH, "w"); if (f) { fprintf(f, "%s\n", c); fclose(f); }
    olog("submitted: %s", c);
}
static void appendOut(const char* s) { FILE* f = fopen(OUT_PATH, "a"); if (f) { fprintf(f, "%s\n", s); fclose(f); } }

// Handle a submitted line. `clear`/`help` are local to the overlay; everything else goes to Frida.
static void handleSubmit(const char* cmd) {
    if (strcmp(cmd, "clear") == 0) { FILE* f = fopen(OUT_PATH, "w"); if (f) fclose(f); g_lines.clear(); return; }
    appendOut((std::string("> ") + cmd).c_str());
    if (strcmp(cmd, "help") == 0) {
        appendOut("items:  give <Items.X> <qty> | removeitem <Items.X> <qty> | money <n>");
        appendOut("        CET style: Game.AddToInventory(\"Items.X\", n)");
        appendOut("char:   perks <n> | attrs <n> | relic <n> | level <n> | heal | godmode [off]");
        appendOut("world:  teleport save <name> | teleport <name> | teleport <x> <y> <z> | setfact <name> <n>");
        appendOut("misc:   call <Class> <method> [args] | sig <Class> <method> | convdump | clear | help");
        appendOut("tip: Up/Down = command history. Bookmark spots: 'teleport save home' then 'teleport home'");
    } else {
        submitCommand(cmd);
    }
    refreshOut();
}

// ---- macOS virtual keycode -> ImGuiKey (control/nav keys + letters for Ctrl shortcuts) ----
static ImGuiKey macKeyToImGui(unsigned short k) {
    switch (k) {
        case 36: return ImGuiKey_Enter;      case 76: return ImGuiKey_KeypadEnter;
        case 48: return ImGuiKey_Tab;        case 49: return ImGuiKey_Space;
        case 51: return ImGuiKey_Backspace;  case 117: return ImGuiKey_Delete;
        case 53: return ImGuiKey_Escape;
        case 123: return ImGuiKey_LeftArrow; case 124: return ImGuiKey_RightArrow;
        case 125: return ImGuiKey_DownArrow; case 126: return ImGuiKey_UpArrow;
        case 115: return ImGuiKey_Home;      case 119: return ImGuiKey_End;
        case 116: return ImGuiKey_PageUp;    case 121: return ImGuiKey_PageDown;
        case 0: return ImGuiKey_A;  case 11: return ImGuiKey_B; case 8: return ImGuiKey_C;  case 2: return ImGuiKey_D;
        case 14: return ImGuiKey_E; case 3: return ImGuiKey_F;  case 5: return ImGuiKey_G;  case 4: return ImGuiKey_H;
        case 34: return ImGuiKey_I; case 38: return ImGuiKey_J; case 40: return ImGuiKey_K; case 37: return ImGuiKey_L;
        case 46: return ImGuiKey_M; case 45: return ImGuiKey_N; case 31: return ImGuiKey_O; case 35: return ImGuiKey_P;
        case 12: return ImGuiKey_Q; case 15: return ImGuiKey_R; case 1: return ImGuiKey_S;  case 17: return ImGuiKey_T;
        case 32: return ImGuiKey_U; case 9: return ImGuiKey_V;  case 13: return ImGuiKey_W; case 7: return ImGuiKey_X;
        case 16: return ImGuiKey_Y; case 6: return ImGuiKey_Z;
        default: return ImGuiKey_None;
    }
}

static void pushMousePos(NSEvent* ev) {
    NSWindow* w = ev.window; if (!w) return;
    NSView* cv = [w contentView]; if (!cv) return;
    NSPoint p = ev.locationInWindow;
    NSPoint vp = [cv convertPoint:p fromView:nil];
    CGFloat h = cv.bounds.size.height;
    CGFloat sc = w.backingScaleFactor;
    g_queue.push_back({2, 0, false, 0, (float)(vp.x * sc), (float)((h - vp.y) * sc)});
}

// Called on the MAIN thread from the sendEvent swizzle. Only queues data; no ImGui calls.
static void pushEventFromNS(NSEvent* ev) {
    NSEventType t = ev.type;
    std::lock_guard<std::mutex> lk(g_qmtx);
    NSEventModifierFlags mf = ev.modifierFlags;
    int mods = 0;
    if (mf & NSEventModifierFlagControl) mods |= 1;
    if (mf & NSEventModifierFlagShift)   mods |= 2;
    if (mf & NSEventModifierFlagOption)  mods |= 4;
    if (mf & NSEventModifierFlagCommand) mods |= 8;
    g_queue.push_back({5, mods, false, 0, 0, 0});
    if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp) {
        bool down = (t == NSEventTypeKeyDown);
        ImGuiKey k = macKeyToImGui(ev.keyCode);
        if (k != ImGuiKey_None) g_queue.push_back({0, (int)k, down, 0, 0, 0});
        if (down && !(mf & NSEventModifierFlagCommand)) { NSString* s = ev.characters; if (s) { for (NSUInteger i = 0; i < s.length; i++) { unichar c = [s characterAtIndex:i]; if (c >= 32 && c != 127) g_queue.push_back({1, 0, false, (unsigned)c, 0, 0}); } } }
    } else if (t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseDown ||
               t == NSEventTypeRightMouseUp || t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDragged ||
               t == NSEventTypeRightMouseDragged) {
        pushMousePos(ev);
        if (t == NSEventTypeLeftMouseDown)       g_queue.push_back({3, 0, true,  0, 0, 0});
        else if (t == NSEventTypeLeftMouseUp)    g_queue.push_back({3, 0, false, 0, 0, 0});
        else if (t == NSEventTypeRightMouseDown) g_queue.push_back({3, 1, true,  0, 0, 0});
        else if (t == NSEventTypeRightMouseUp)   g_queue.push_back({3, 1, false, 0, 0, 0});
    } else if (t == NSEventTypeScrollWheel) {
        pushMousePos(ev);
        g_queue.push_back({4, 0, false, 0, (float)ev.scrollingDeltaX * 0.1f, (float)ev.scrollingDeltaY * 0.1f});
    }
}

static void drainEvents() {
    std::lock_guard<std::mutex> lk(g_qmtx);
    ImGuiIO& io = ImGui::GetIO();
    for (auto& e : g_queue) {
        switch (e.type) {
            case 0: io.AddKeyEvent((ImGuiKey)e.code, e.down); break;
            case 1: io.AddInputCharacter(e.ch); break;
            case 2: io.AddMousePosEvent(e.x, e.y); break;
            case 3: io.AddMouseButtonEvent(e.code, e.down); break;
            case 4: io.AddMouseWheelEvent(e.x, e.y); break;
            case 5: io.AddKeyEvent(ImGuiMod_Ctrl, e.code & 1); io.AddKeyEvent(ImGuiMod_Shift, e.code & 2);
                    io.AddKeyEvent(ImGuiMod_Alt, e.code & 4); io.AddKeyEvent(ImGuiMod_Super, e.code & 8); break;
        }
    }
    g_queue.clear();
}

// macOS clipboard (NSPasteboard) so Cmd+V / Cmd+C work in the console input
static const char* clip_get(ImGuiContext*) {
    static std::string s;
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* str = [pb stringForType:NSPasteboardTypeString];
    s = (str != nil) ? std::string([str UTF8String]) : std::string();
    return s.c_str();
}
static void clip_set(ImGuiContext*, const char* text) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    if (text) [pb setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
}

static void initImGui(id<MTLDevice> dev) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigMacOSXBehaviors = true;   // Cmd-based shortcuts (Cmd+V paste, Cmd+C copy, Cmd+A select-all)
    ImGuiPlatformIO& pio = ImGui::GetPlatformIO();
    pio.Platform_GetClipboardTextFn = clip_get;
    pio.Platform_SetClipboardTextFn = clip_set;
    ImGui::StyleColorsDark();
    ImGui_ImplMetal_Init(dev);
    refreshOut();
    g_imguiInit = true;
    olog("ImGui %s initialized", IMGUI_VERSION);
}

// Up/Down arrow command history for the input box.
static int inputCallback(ImGuiInputTextCallbackData* data) {
    if (data->EventFlag == ImGuiInputTextFlags_CallbackHistory) {
        int prev = g_historyPos;
        if (data->EventKey == ImGuiKey_UpArrow) {
            if (g_historyPos == -1) g_historyPos = (int)g_history.size() - 1;
            else if (g_historyPos > 0) g_historyPos--;
        } else if (data->EventKey == ImGuiKey_DownArrow) {
            if (g_historyPos != -1 && ++g_historyPos >= (int)g_history.size()) g_historyPos = -1;
        }
        if (prev != g_historyPos) {
            const char* s = (g_historyPos >= 0 && g_historyPos < (int)g_history.size()) ? g_history[g_historyPos].c_str() : "";
            data->DeleteChars(0, data->BufTextLen);
            data->InsertChars(0, s);
        }
    }
    return 0;
}

static void drawConsole() {
    ImGui::SetNextWindowSize(ImVec2(820, 460), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(48, 48), ImGuiCond_FirstUseEver);
    ImGui::Begin("CP2077 mini-CET  ( ` or F1 to toggle )");
    ImGui::BeginChild("scroll", ImVec2(0, -ImGui::GetFrameHeightWithSpacing()), false, ImGuiWindowFlags_HorizontalScrollbar);
    for (auto& l : g_lines) ImGui::TextUnformatted(l.c_str());
    if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 4.0f) ImGui::SetScrollHereY(1.0f);
    ImGui::EndChild();
    ImGui::Separator();
    ImGui::SetNextItemWidth(-1.0f);
    if (g_focusInput.exchange(false)) ImGui::SetKeyboardFocusHere();
    ImGuiInputTextFlags flags = ImGuiInputTextFlags_EnterReturnsTrue | ImGuiInputTextFlags_CallbackHistory;
    if (ImGui::InputText("##cmd", g_input, sizeof(g_input), flags, inputCallback)) {
        if (g_input[0]) {
            if (g_history.empty() || g_history.back() != g_input) g_history.push_back(g_input);
            g_historyPos = -1;
            handleSubmit(g_input);
            g_input[0] = 0;
        }
        ImGui::SetKeyboardFocusHere(-1);
    }
    ImGui::End();
}

static void renderOverlay(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable) {
    if (!cb || !drawable) return;
    id<MTLTexture> tex = drawable.texture; if (!tex) return;
    id<MTLDevice> dev = cb.device;
    if (!g_imguiInit) initImGui(dev);
    g_frame++;
    if ((g_frame % 60) == 0) refreshOut();

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = tex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)tex.width, (float)tex.height);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    io.DeltaTime = 1.0f / 60.0f;
    drainEvents();

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    if (g_show.load()) drawConsole();
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    if (!enc) return;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
}

static void my_presentDrawable(id self, SEL _cmd, id drawable) {
    @autoreleasepool {
        @try { renderOverlay((id<MTLCommandBuffer>)self, (id<CAMetalDrawable>)drawable); }
        @catch (NSException* e) { olog("render exception: %s", [[e reason] UTF8String]); }
    }
    ((void(*)(id, SEL, id))g_origPresent)(self, _cmd, drawable);
}

static void my_sendEvent(id self, SEL _cmd, NSEvent* ev) {
    @try {
        NSEventType t = ev.type;
        if (t == NSEventTypeKeyDown) {
            unsigned short kc = ev.keyCode;
            if (kc == 50 || kc == 122) {  // ` (grave/tilde) or F1
                bool now = !g_show.load();
                g_show = now;
                if (now) { g_focusInput = true; NSWindow* w = ev.window; if (w) [w setAcceptsMouseMovedEvents:YES]; }
                return;  // swallow the toggle key
            }
        }
        if (g_show.load()) {
            pushEventFromNS(ev);
            if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp || t == NSEventTypeFlagsChanged ||
                t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseDown ||
                t == NSEventTypeRightMouseUp || t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDragged ||
                t == NSEventTypeRightMouseDragged || t == NSEventTypeScrollWheel)
                return;  // swallow so the game doesn't react while the console is open
        }
    } @catch (NSException* e) { olog("sendEvent exception: %s", [[e reason] UTF8String]); }
    ((void(*)(id, SEL, id))g_origSendEvent)(self, _cmd, ev);
}

static void installPresentHook() {
    Class cbClass = nil;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev) {
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (cb) cbClass = object_getClass(cb);
    }
    if (!cbClass) {
        int n = objc_getClassList(NULL, 0);
        Class* list = (Class*)malloc(sizeof(Class) * n);
        objc_getClassList(list, n);
        for (int i = 0; i < n; i++) {
            const char* nm = class_getName(list[i]);
            if (nm && strstr(nm, "FamilyCommandBuffer") && strncmp(nm, "AGX", 3) == 0) { cbClass = list[i]; break; }
        }
        free(list);
    }
    if (!cbClass) { olog("FATAL: could not find a command-buffer class"); return; }
    SEL sel = sel_registerName("presentDrawable:");
    Method m = class_getInstanceMethod(cbClass, sel);
    if (!m) { olog("FATAL: no presentDrawable: on %s", class_getName(cbClass)); return; }
    g_origPresent = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_presentDrawable);
    olog("hooked presentDrawable: on %s", class_getName(cbClass));
}

static void installInputHook() {
    id app = ((id(*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    if (!app) { olog("FATAL: no NSApplication"); return; }
    Class appClass = object_getClass(app);
    SEL sel = sel_registerName("sendEvent:");
    Method m = class_getInstanceMethod(appClass, sel);
    if (!m) { olog("FATAL: no sendEvent: on %s", class_getName(appClass)); return; }
    g_origSendEvent = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_sendEvent);
    olog("hooked sendEvent: on %s", class_getName(appClass));
}

__attribute__((constructor))
static void overlay_init() {
    olog("==== CP2077 overlay dylib loaded ====");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installPresentHook();
        installInputHook();
    });
}
