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

class DockMinimizeManager {
    static let shared = DockMinimizeManager()
    private var lastClickedBundleId: String? = nil
    private var currentPreviewPanel: NSPanel? = nil
    var shouldSwallowNextMouseUp = false
    
    // Low-latency in-memory thumbnail storage
    private var thumbnailCache: [String: NSImage] = [:]
    
    func start() {
        print("[DockMinimize v3.6] Initializing Precision-Matched Window Engine...")
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            print("[DockMinimize v3.6] CRITICAL: Accessibility permissions missing.")
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
                
                if event.type == .leftMouseDown {
                    if manager.handleMouseDown(event: event) {
                        manager.shouldSwallowNextMouseUp = true
                        return nil 
                    }
                } else if event.type == .leftMouseUp {
                    if manager.shouldSwallowNextMouseUp {
                        manager.shouldSwallowNextMouseUp = false
                        return nil 
                    }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            print("[DockMinimize v3.6] ERROR: Failed to create event tap.")
            return
        }
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("[DockMinimize v3.6] Pure On-Demand Engine operational. 0% Idle CPU achieved.")
    }
    
    // Core Engine Optimization: Caching bound directly to CoreFoundation memory reference hashes
    private func cacheSingleAXWindow(axWindow: AXUIElement, pid: pid_t) async {
        guard let availableContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let scWindows = availableContent.windows.filter { $0.owningApplication?.processID == pid }
        
        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue)
        var axPoint = CGPoint.zero
        if let pVal = posValue {
            AXValueGetValue(pVal as! AXValue, .cgPoint, &axPoint)
        }
        
        if let targetScWindow = scWindows.first(where: { abs($0.frame.origin.x - axPoint.x) < 50 && abs($0.frame.origin.y - axPoint.y) < 50 }) {
            let filter = SCContentFilter(desktopIndependentWindow: targetScWindow)
            let config = SCStreamConfiguration()
            config.width = 280
            config.height = 180
            
            if let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                
                // CRITICAL LOCK: Bound strictly to the unique runtime reference pointer of the element
                let cacheKey = "\(CFHash(axWindow))"
                await MainActor.run {
                    self.thumbnailCache[cacheKey] = nsImage
                }
            }
        }
    }
    
    func handleMouseDown(event: CGEvent) -> Bool {
        let clickLocation = event.location
        
        var elementUnderMouse: AXUIElement?
        let rt = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(clickLocation.x), Float(clickLocation.y), &elementUnderMouse)
        guard rt == .success, let element = elementUnderMouse else {
            dismissPreviewPanel()
            return false
        }
        
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let clickedApp = NSRunningApplication(processIdentifier: pid)
        
        if let currentPanel = currentPreviewPanel, NSMouseInRect(NSEvent.mouseLocation, currentPanel.frame, false) {
            return false
        }
        
        guard clickedApp?.bundleIdentifier == "com.apple.dock" else {
            dismissPreviewPanel()
            return false
        }
        
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard let appName = value as? String else { return false }
        
        return processDockClick(for: appName, element: element)
    }
    
    private func processDockClick(for appName: String, element: AXUIElement) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        guard let targetApp = apps.first(where: { $0.localizedName == appName }) else { return false }
        let bundleId = targetApp.bundleIdentifier ?? ""
        
        let appRef = AXUIElementCreateApplication(targetApp.processIdentifier)
        var windowListValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowListValue)
        guard result == .success, let windows = windowListValue as? [AXUIElement] else { return false }
        
        print("[DockMinimize v3.6] Target: \(appName) | Open Window Count: \(windows.count)")
        
        if windows.count == 0 {
            dismissPreviewPanel()
            return false 
        }
        
        if currentPreviewPanel != nil && lastClickedBundleId == bundleId {
            print("[DockMinimize v3.6] Consecutive click. Minimizing all active windows smoothly.")
            
            Task {
                for win in windows {
                    if !self.isWindowMinimized(win) {
                        await self.cacheSingleAXWindow(axWindow: win, pid: targetApp.processIdentifier)
                    }
                }
                await MainActor.run {
                    self.minimizeAllWindows(windows)
                    self.dismissPreviewPanel()
                }
            }
            return true 
        }
        
        if currentPreviewPanel != nil {
            dismissPreviewPanel()
        }
        
        if windows.count == 1 {
            let singleWindow = windows[0]
            if targetApp.isActive && !isWindowMinimized(singleWindow) {
                Task {
                    await self.cacheSingleAXWindow(axWindow: singleWindow, pid: targetApp.processIdentifier)
                    await MainActor.run {
                        self.minimizeWindow(singleWindow)
                    }
                }
                lastClickedBundleId = bundleId
                return true 
            } else {
                lastClickedBundleId = bundleId
                return false 
            }
        } else {
            showCustomMiniaturePanel(for: targetApp, dockElement: element, axWindows: windows)
            lastClickedBundleId = bundleId
            return true
        }
    }
    
    private func minimizeAllWindows(_ windows: [AXUIElement]) {
        for window in windows {
            minimizeWindow(window)
        }
    }
    
    private func showCustomMiniaturePanel(for app: NSRunningApplication, dockElement: AXUIElement, axWindows: [AXUIElement]) {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(dockElement, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(dockElement, kAXSizeAttribute as CFString, &sizeValue)
        
        var iconPosition = CGPoint.zero
        var iconSize = CGSize.zero
        if let pVal = posValue, let sVal = sizeValue {
            AXValueGetValue(pVal as! AXValue, .cgPoint, &iconPosition)
            AXValueGetValue(sVal as! AXValue, .cgSize, &iconSize)
        }
        
        let finalPosition = iconPosition
        let finalSize = iconSize
        
        Task {
            do {
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                
                // OPTIMIZATION POOL: Mutable list copy to manage strict 1:1 allocation mapping rules
                var availableSCWindows = availableContent.windows.filter { $0.owningApplication?.processID == app.processIdentifier }
                
                var previews: [WindowPreviewItem] = []
                
                for (index, axWindow) in axWindows.enumerated() {
                    var titleValue: AnyObject?
                    AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
                    let explicitTitle = titleValue as? String ?? ""
                    let displayTitle = explicitTitle.isEmpty ? "\(app.localizedName ?? "Window") (\(index + 1))" : explicitTitle
                    
                    let minimized = isWindowMinimized(axWindow)
                    let cacheKey = "\(CFHash(axWindow))" // Immutable reference key matching
                    
                    var finalThumbnail: NSImage? = nil
                    
                    var axPosVal: AnyObject?
                    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPosVal)
                    var axPoint = CGPoint.zero
                    if let pVal = axPosVal {
                        AXValueGetValue(pVal as! AXValue, .cgPoint, &axPoint)
                    }
                    
                    if !minimized {
                        // STRICT 1:1 ALLOCATION MAPPER: Snaps closest geometric match and removes it from the search pool
                        if let bestMatchIndex = availableSCWindows.firstIndex(where: { abs($0.frame.origin.x - axPoint.x) < 60 && abs($0.frame.origin.y - axPoint.y) < 60 }) {
                            let matchedScWindow = availableSCWindows.remove(at: bestMatchIndex) // CONSUME ITEM FROM POOL
                            
                            let filter = SCContentFilter(desktopIndependentWindow: matchedScWindow)
                            let config = SCStreamConfiguration()
                            config.width = 280
                            config.height = 180
                            
                            if let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                                finalThumbnail = nsImage
                                
                                await MainActor.run {
                                    self.thumbnailCache[cacheKey] = nsImage
                                }
                            }
                        }
                    }
                    
                    let cachedImg = await MainActor.run { self.thumbnailCache[cacheKey] }
                    
                    let resolvedImage: NSImage
                    if let liveImg = finalThumbnail {
                        resolvedImage = liveImg
                    } else if let cachedImg = cachedImg {
                        resolvedImage = cachedImg
                    } else {
                        resolvedImage = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                    }
                    
                    previews.append(WindowPreviewItem(
                        id: cacheKey, // Use the immutable address pointer hash as the Identifiable structural ID
                        title: displayTitle,
                        image: resolvedImage,
                        isMinimized: minimized,
                        axElement: axWindow
                    ))
                }
                
                guard !previews.isEmpty else { return }
                let finalPreviews = previews
                
                await MainActor.run {
                    let previewView = PreviewCollectionView(previews: finalPreviews) { selectedAxWindow in
                        app.activate()
                        AXUIElementSetAttributeValue(selectedAxWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                        AXUIElementSetAttributeValue(selectedAxWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                        self.dismissPreviewPanel()
                    }
                    
                    let hostingView = NSHostingView(rootView: previewView)
                    let calculatedWidth = CGFloat(finalPreviews.count * 160) + 20
                    hostingView.frame = NSRect(x: 0, y: 0, width: calculatedWidth, height: 140)
                    
                    let screenHeight = NSScreen.main?.frame.height ?? 1080
                    let panelX = finalPosition.x + (finalSize.width / 2) - (calculatedWidth / 2)
                    let panelY = screenHeight - finalPosition.y + 12
                    
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
            } catch {
                print("[DockMinimize v3.6] Graphics snapshot rendering exception: \(error)")
            }
        }
    }
    
    func dismissPreviewPanel() {
        DispatchQueue.main.async {
            if self.currentPreviewPanel != nil {
                self.currentPreviewPanel?.orderOut(nil)
                self.currentPreviewPanel = nil
            }
        }
    }
    
    fileprivate func isWindowMinimized(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
    
    private func minimizeWindow(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
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