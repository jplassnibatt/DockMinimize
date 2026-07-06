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
    
    // Thread-safe state bridge for the low-level event tap callback
    private let stateLock = NSLock()
    private var _shouldSwallowNextMouseUp = false
    var shouldSwallowNextMouseUp: Bool {
        get { stateLock.withLock { _shouldSwallowNextMouseUp } }
        set { stateLock.withLock { _shouldSwallowNextMouseUp = newValue } }
    }
    
    // Low-latency in-memory thumbnail storage
    private var thumbnailCache: [String: NSImage] = [:]
    
    func start() {
        print("[DockMinimize v3.7] Initializing Warning-Free AppKit Engine...")
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            print("[DockMinimize v3.7] CRITICAL: Accessibility permissions missing.")
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
                        return nil // Swallow original click event
                    }
                } else if type == .leftMouseUp {
                    if manager.shouldSwallowNextMouseUp {
                        manager.shouldSwallowNextMouseUp = false
                        return nil // Swallow paired mouse release
                    }
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("[DockMinimize v3.7] ERROR: Failed to create event tap.")
            return
        }
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("[DockMinimize v3.7] Pure On-Demand Engine operational.")
    }
    
    private func evaluateClickSynchronously(at location: CGPoint) -> Bool {
        var elementUnderMouse: AXUIElement?
        let rt = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y), &elementUnderMouse)
        
        guard rt == .success, let element = elementUnderMouse else { return false }
        
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let clickedApp = NSRunningApplication(processIdentifier: pid)
        
        if clickedApp?.bundleIdentifier == "com.apple.dock" {
            Task { @MainActor in
                await self.processDockClickAsync(element: element)
            }
            return true
        }
        
        Task { @MainActor in self.dismissPreviewPanel() }
        return false
    }
    
    private func processDockClickAsync(element: AXUIElement) async {
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
        
        var targetPid: pid_t = 0
        var childrenValue: AnyObject?
        
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                var childPid: pid_t = 0
                AXUIElementGetPid(child, &childPid)
                if childPid != 0, let candidateApp = NSRunningApplication(processIdentifier: childPid),
                   candidateApp.bundleIdentifier != "com.apple.dock",
                   candidateApp.activationPolicy == .regular {
                    targetPid = childPid
                    break
                }
            }
        }
        
        let apps = NSWorkspace.shared.runningApplications
        
        if targetPid == 0 && !appName.isEmpty {
            if let targetApp = apps.first(where: { 
                $0.activationPolicy == .regular && (
                    $0.localizedName == appName ||
                    $0.localizedName?.localizedCaseInsensitiveContains(appName) == true ||
                    appName.localizedCaseInsensitiveContains($0.localizedName ?? "") == true
                )
            }) {
                targetPid = targetApp.processIdentifier
            }
        }
        
        if targetPid == 0 {
            if !appName.isEmpty, let targetApp = apps.first(where: {
                $0.activationPolicy == .regular && $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
            }) {
                targetPid = targetApp.processIdentifier
            } else if appName.isEmpty {
                if let targetApp = apps.first(where: { $0.activationPolicy == .regular && $0.bundleIdentifier?.localizedCaseInsensitiveContains("iterm") == true }) {
                    targetPid = targetApp.processIdentifier
                }
            }
        }
        
        guard targetPid != 0, let targetApp = NSRunningApplication(processIdentifier: targetPid) else { 
            print("[DockMinimize v3.7] Target application unidentified for name: '\(appName)'")
            return 
        }
        
        let bundleId = targetApp.bundleIdentifier ?? ""
        let appRef = AXUIElementCreateApplication(targetPid)
        var windowListValue: AnyObject?
        
        // OPTIMIZATION: Replacing deprecated options with modern cooperative activation alternatives
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowListValue) == .success,
              let windows = windowListValue as? [AXUIElement], !windows.isEmpty else {
            print("[DockMinimize v3.7] Empty window matrix for \(targetApp.localizedName ?? "App"). Triggering Safety Valve Toggle.")
            if !targetApp.isActive {
                targetApp.activate(options: .activateAllWindows)
                AXUIElementSetAttributeValue(appRef, kAXHiddenAttribute as CFString, kCFBooleanFalse)
            } else {
                targetApp.hide()
                AXUIElementSetAttributeValue(appRef, kAXHiddenAttribute as CFString, kCFBooleanTrue)
            }
            dismissPreviewPanel()
            return
        }
        
        if currentPreviewPanel != nil && lastClickedBundleId == bundleId {
            for win in windows where !isWindowMinimized(win) {
                await cacheSingleAXWindow(axWindow: win, pid: targetPid)
            }
            minimizeAllWindows(windows)
            dismissPreviewPanel()
            return
        }
        
        if currentPreviewPanel != nil { dismissPreviewPanel() }
        
        if windows.count == 1 {
            let singleWindow = windows[0]
            if targetApp.isActive && !isWindowMinimized(singleWindow) {
                await cacheSingleAXWindow(axWindow: singleWindow, pid: targetPid)
                minimizeWindow(singleWindow)
                lastClickedBundleId = bundleId
            } else {
                targetApp.activate(options: .activateAllWindows)
                AXUIElementSetAttributeValue(singleWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                lastClickedBundleId = bundleId
            }
        } else {
            await showCustomMiniaturePanel(for: targetApp, dockElement: element, axWindows: windows)
            lastClickedBundleId = bundleId
        }
    }
    
    private func cacheSingleAXWindow(axWindow: AXUIElement, pid: pid_t) async {
        guard let availableContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let scWindows = availableContent.windows.filter { $0.owningApplication?.processID == pid }
        
        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue)
        var axPoint = CGPoint.zero
        if let pVal = posValue { AXValueGetValue(pVal as! AXValue, .cgPoint, &axPoint) }
        
        if let targetScWindow = scWindows.first(where: { abs($0.frame.origin.x - axPoint.x) < 50 && abs($0.frame.origin.y - axPoint.y) < 50 }) {
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
                if let bestMatchIndex = availableSCWindows.firstIndex(where: { abs($0.frame.origin.x - axPoint.x) < 60 && abs($0.frame.origin.y - axPoint.y) < 60 }) {
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
        
        guard !previews.isEmpty else {
            if !app.isActive {
                app.activate(options: .activateAllWindows)
            } else {
                app.hide()
            }
            return
        }
        
        let previewView = PreviewCollectionView(previews: previews) { selectedAxWindow in
            app.activate(options: .activateAllWindows)
            AXUIElementSetAttributeValue(selectedAxWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
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
    }
    
    func dismissPreviewPanel() {
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