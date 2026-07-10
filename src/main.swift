import Cocoa
import ApplicationServices
import SwiftUI
import ScreenCaptureKit

struct WindowPreviewItem: Identifiable {
    let id: String
    let title: String
    let image: NSImage
    let isMinimized: Bool
    let axElement: AXUIElement
}

@MainActor
class DockMinimizeManager {
    static let shared = DockMinimizeManager()
    
    private var lastClickedBundleId: String? = nil
    private var currentPreviewPanel: NSPanel? = nil
    private var lastClickTime = Date()
    
    private let stateLock = NSLock()
    private var _shouldSwallowNextMouseUp = false
    var shouldSwallowNextMouseUp: Bool {
        get { stateLock.withLock { _shouldSwallowNextMouseUp } }
        set { stateLock.withLock { _shouldSwallowNextMouseUp = newValue } }
    }
    
    private var thumbnailCache: [String: NSImage] = [:]
    
    private var autoDismissTask: Task<Void, Never>? = nil
    
    func start() {
        print("[DockMinimize v4.1] Initializing Bulletproof Loop Engine...")
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            print("[DockMinimize v4.1] CRITICAL: Accessibility permissions missing.")
            return
        }
        
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let manager = DockMinimizeManager.shared
                
                if type == .leftMouseDown {
                    let location = event.location
                    if manager.evaluateClickSynchronously(at: location) {
                        manager.shouldSwallowNextMouseUp = true
                        return nil
                    }
                } else if type == .leftMouseUp {
                    if manager.shouldSwallowNextMouseUp {
                        manager.shouldSwallowNextMouseUp = false
                        return nil
                    }
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("[DockMinimize v4.1] ERROR: Failed to create event tap.")
            return
        }
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("[DockMinimize v4.1] Pure On-Demand Engine operational.")
    }
    
    private func evaluateClickSynchronously(at location: CGPoint) -> Bool {
        var elementUnderMouse: AXUIElement?
        let rt = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y), &elementUnderMouse)
        
        guard rt == .success, let element = elementUnderMouse else { return false }
        
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let clickedApp = NSRunningApplication(processIdentifier: pid) else { return false }
        
        guard clickedApp.bundleIdentifier == "com.apple.dock" else { return false }
        
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        var appName = titleValue as? String ?? ""
        
        if appName.isEmpty {
            var descValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
            if let desc = descValue as? String {
                appName = desc.replacingOccurrences(of: " application icon", with: "")
                             .replacingOccurrences(of: " icon", with: "")
                             .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        guard let targetApp = resolveTargetProcess(for: element, appName: appName) else {
            return false
        }
        
        let targetPid = targetApp.processIdentifier
        let bundleId = targetApp.bundleIdentifier ?? ""
        
        if bundleId == "com.apple.finder" {
            let scriptSource = """
            tell application "Finder"
                try
                    if (count of Finder windows) is 0 then
                        return "native"
                    end if
                    
                    if frontmost is false then
                        return "native"
                    else
                        if collapsed of Finder window 1 is true then
                            set collapsed of Finder window 1 to false
                            activate
                            return "swallow"
                        else
                            set collapsed of Finder window 1 to true
                            return "swallow"
                        end if
                    end if
                on error
                    return "native"
                end try
            end tell
            """
            
            if let script = NSAppleScript(source: scriptSource) {
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let stringResult = result.stringValue, stringResult == "swallow" {
                    lastClickedBundleId = bundleId
                    lastClickTime = Date()
                    return true
                }
            }
            lastClickedBundleId = bundleId
            lastClickTime = Date()
            return false
        }
        
        let appRef = AXUIElementCreateApplication(targetPid)
        var windowListValue: AnyObject?
        
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowListValue) == .success,
              let rawWindows = windowListValue as? [AXUIElement] else {
            return false
        }
        
        // Exclude persistent background wallpaper substrate windows via our upgraded standard filter
        let windows = rawWindows.filter { isStandardWindow($0) }
        
        if windows.isEmpty {
            return false
        }
        
        if currentPreviewPanel != nil && lastClickedBundleId != bundleId {
            Task { @MainActor in self.dismissPreviewPanel() }
        }
        
        if currentPreviewPanel != nil && lastClickedBundleId == bundleId {
            Task { @MainActor in
                for win in windows where !self.isWindowMinimized(win) {
                    await self.cacheSingleAXWindow(axWindow: win, pid: targetPid)
                }
                self.minimizeAllWindows(windows)
                self.dismissPreviewPanel()
            }
            return true
        }
        
        if windows.count == 1 {
            let singleWindow = windows[0]
            let isMinimized = isWindowMinimized(singleWindow)
            
            if targetApp.isActive && !isMinimized {
                let now = Date()
                if lastClickedBundleId == bundleId && now.timeIntervalSince(lastClickTime) < 0.4 {
                    return true 
                }
                lastClickTime = now
                lastClickedBundleId = bundleId
                
                Task { @MainActor in
                    await self.cacheSingleAXWindow(axWindow: singleWindow, pid: targetPid)
                    self.minimizeWindow(singleWindow)
                }
                return true
            } else {
                lastClickedBundleId = bundleId
                lastClickTime = Date()
                
                Task { @MainActor in
                    targetApp.activate(options: .activateAllWindows)
                    if isMinimized {
                        AXUIElementSetAttributeValue(singleWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                        // NEW: Explicitly perform the HIG Raise Action to force Custom UI Apps (Zoom) to render context
                        AXUIElementPerformAction(singleWindow, kAXRaiseAction as CFString)
                        AXUIElementSetAttributeValue(singleWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                    }
                }
                return isMinimized
            }
        } else {
            lastClickedBundleId = bundleId
            lastClickTime = Date()
            Task { @MainActor in
                if self.currentPreviewPanel != nil { self.dismissPreviewPanel() }
                await self.showCustomMiniaturePanel(for: targetApp, dockElement: element, axWindows: windows)
            }
            return true
        }
    }
    
    private func resolveTargetProcess(for element: AXUIElement, appName: String) -> NSRunningApplication? {
        if appName.localizedCaseInsensitiveContains("Finder") {
            return NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" })
        }
        
        var childrenValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                var childPid: pid_t = 0
                AXUIElementGetPid(child, &childPid)
                if childPid != 0, let candidateApp = NSRunningApplication(processIdentifier: childPid),
                   candidateApp.bundleIdentifier != "com.apple.dock",
                   candidateApp.activationPolicy == .regular {
                    return candidateApp
                }
            }
        }
        
        let apps = NSWorkspace.shared.runningApplications
        
        if !appName.isEmpty {
            if let targetApp = apps.first(where: { 
                $0.activationPolicy == .regular && (
                    $0.localizedName == appName ||
                    $0.localizedName?.localizedCaseInsensitiveContains(appName) == true ||
                    appName.localizedCaseInsensitiveContains($0.localizedName ?? "") == true
                )
            }) {
                return targetApp
            }
        }
        
        if !appName.isEmpty {
            if let targetApp = apps.first(where: {
                $0.activationPolicy == .regular && $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
            }) {
                return targetApp
            }
        } else {
            if let targetApp = apps.first(where: { $0.activationPolicy == .regular && $0.bundleIdentifier?.localizedCaseInsensitiveContains("iterm") == true }) {
                return targetApp
            }
        }
        
        return nil
    }
    
    fileprivate func isStandardWindow(_ window: AXUIElement) -> Bool {
        // =========================================================================
        // NEW: ROBUST SUBSTRATE SIZE FILTER
        // Zoom and Electron apps spawn invisible 1x1 or 0x0 overlay windows for tooltips.
        // We must filter these out based on geometric size to avoid polluting the preview pane.
        // =========================================================================
        var sizeValue: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sVal = sizeValue {
            var size = CGSize.zero
            if CFGetTypeID(sVal) == AXValueGetTypeID() {
                AXValueGetValue(sVal as! AXValue, .cgSize, &size)
                if size.width < 50 || size.height < 50 { return false }
            }
        }
        
        // =========================================================================
        // NEW: BROADENED AXSUBROLE EVALUATION
        // Zoom drops the "AXStandardWindow" subrole and downgrades meeting windows
        // to "AXDialog" or "AXDocumentPanel" when minimized or manipulated.
        // =========================================================================
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success else { return true }
        
        if let subrole = value as? String {
            let validSubroles = ["AXStandardWindow", "AXDialog", "AXDocumentPanel"]
            return validSubroles.contains(subrole)
        }
        return true
    }
    
    private func cacheSingleAXWindow(axWindow: AXUIElement, pid: pid_t) async {
        guard let availableContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let scWindows = availableContent.windows.filter { $0.owningApplication?.processID == pid }
        
        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue)
        var axPoint = CGPoint.zero
        if let pVal = posValue { AXValueGetValue(pVal as! AXValue, .cgPoint, &axPoint) }
        
        if let targetScWindow = scWindows.first(where: { window in
            let deltaX = abs(window.frame.origin.x - axPoint.x)
            let deltaY = abs(window.frame.origin.y - axPoint.y)
            return deltaX < 50 && deltaY < 50
        }) {
            let filter = SCContentFilter(desktopIndependentWindow: targetScWindow)
            let config = SCStreamConfiguration()
            config.width = 280
            config.height = 180
            
            if let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.thumbnailCache["\(CFHash(axWindow))"] = nsImage
            }
        }
    }
    
    private func minimizeWindow(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
    
    private func minimizeAllWindows(_ windows: [AXUIElement]) {
        windows.forEach { minimizeWindow($0) }
    }
    
    private func showCustomMiniaturePanel(for app: NSRunningApplication, dockElement: AXUIElement, axWindows: [AXUIElement]) async {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(dockElement, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(dockElement, kAXSizeAttribute as CFString, &sizeValue)
        
        var iconPosition = CGPoint.zero
        var iconSize = CGSize.zero
        if let pVal = posValue { AXValueGetValue(pVal as! AXValue, .cgPoint, &iconPosition) }
        if let sVal = sizeValue { AXValueGetValue(sVal as! AXValue, .cgSize, &iconSize) }
        
        guard let availableContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        var availableSCWindows = availableContent.windows.filter { $0.owningApplication?.processID == app.processIdentifier }
        
        var previews: [WindowPreviewItem] = []
        
        for (index, axWindow) in axWindows.enumerated() {
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
            let explicitTitle = titleValue as? String ?? ""
            let displayTitle = explicitTitle.isEmpty ? "\(app.localizedName ?? "Window") (\(index + 1))" : explicitTitle
            
            let minimized = isWindowMinimized(axWindow)
            let cacheKey = "\(CFHash(axWindow))"
            var finalThumbnail: NSImage? = nil
            
            var axPosVal: AnyObject?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPosVal)
            var axPoint = CGPoint.zero
            if let pVal = axPosVal { AXValueGetValue(pVal as! AXValue, .cgPoint, &axPoint) }
            
            if !minimized {
                if let bestMatchIndex = availableSCWindows.firstIndex(where: { scWindow in
                    let deltaX = abs(scWindow.frame.origin.x - axPoint.x)
                    let deltaY = abs(scWindow.frame.origin.y - axPoint.y)
                    return deltaX < 60 && deltaY < 60
                }) {
                    let matchedScWindow = availableSCWindows.remove(at: bestMatchIndex)
                    let filter = SCContentFilter(desktopIndependentWindow: matchedScWindow)
                    let config = SCStreamConfiguration()
                    config.width = 280
                    config.height = 180
                    
                    if let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        finalThumbnail = nsImage
                        self.thumbnailCache[cacheKey] = nsImage
                    }
                }
            }
            
            let resolvedImage = finalThumbnail ?? self.thumbnailCache[cacheKey] ?? app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
            
            previews.append(WindowPreviewItem(
                id: cacheKey,
                title: displayTitle,
                image: resolvedImage,
                isMinimized: minimized,
                axElement: axWindow
            ))
        }
        
        guard !previews.isEmpty else { return }
        
        let previewView = PreviewCollectionView(previews: previews) { selectedAxWindow in
            app.activate(options: .activateAllWindows)
            AXUIElementSetAttributeValue(selectedAxWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            // NEW: Explicit HIG Window Raise to combat Custom UI render drops
            AXUIElementPerformAction(selectedAxWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(selectedAxWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            self.dismissPreviewPanel()
        }
        
        let hostingView = NSHostingView(rootView: previewView)
        let calculatedWidth = CGFloat(previews.count * 160) + 20
        hostingView.frame = NSRect(x: 0, y: 0, width: calculatedWidth, height: 140)
        
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let panelX = iconPosition.x + (iconSize.width / 2) - (calculatedWidth / 2)
        let panelY = screenHeight - iconPosition.y + 12
        
        let panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: calculatedWidth, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hostingView
        
        panel.orderFrontRegardless()
        self.currentPreviewPanel = panel
        
        autoDismissTask?.cancel()
        
        autoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self.dismissPreviewPanel()
                print("[DockMinimize v4.1] Miniature panel auto-dismissed after 5 seconds of inactivity.")
            } catch {
            }
        }
    }
    
    func dismissPreviewPanel() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        
        if let panel = currentPreviewPanel {
            panel.orderOut(nil)
            currentPreviewPanel = nil
        }
    }
    
    fileprivate func isWindowMinimized(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

struct PreviewCollectionView: View {
    let previews: [WindowPreviewItem]
    let onSelect: (AXUIElement) -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ForEach(previews) { item in
                VStack(spacing: 6) {
                    Image(nsImage: item.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 140, height: 90)
                        .cornerRadius(6)
                        .shadow(radius: item.isMinimized ? 1 : 3)
                        .opacity(item.isMinimized ? 0.70 : 1.0)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(item.isMinimized ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                    
                    Text(item.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(width: 140)
                }
                .padding(6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(item.axElement)
                }
            }
        }
        .padding(10)
        .background(VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 16)))
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockMinimizeManager.shared.start()
    }
}

@main
struct AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}