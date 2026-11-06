import AppKit
import ApplicationServices

// Allow control without macOS's own prompt: opens the Accessibility list in System Settings and hangs a card from that
// window, to drag AirPointer into the list. It follows the window, shows only while System Settings is in front, and
// goes away once the permission arrives.
final class AccessibilityGuide {
    static let shared=AccessibilityGuide()
    private static let settingsApp="com.apple.systempreferences",giveUpAfter=10.0
    private static let size=NSSize(width:460,height:132),inset:CGFloat=16,aboveButtons:CGFloat=40,sidebar:CGFloat=260,narrowest:CGFloat=300
    private let panel=AccessibilityGuidePanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
    private var timer:Timer?,openedAt=0.0

    private init() {
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        panel.level = .floating;panel.collectionBehavior=[.fullScreenAuxiliary,.ignoresCycle]
        panel.isExcludedFromWindowsMenu=true;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false
        panel.animationBehavior = .none;panel.contentView=AccessibilityGuideView()
    }
    func open() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"){NSWorkspace.shared.open(url)}
        openedAt=ProcessInfo.processInfo.systemUptime
        guard timer==nil else{return}
        // In common modes so it keeps up while the window is being moved.
        let timer=Timer(timeInterval:0.1,repeats:true){[weak self] _ in self?.follow()}
        RunLoop.main.add(timer,forMode:.common);self.timer=timer
    }
    func stop(){timer?.invalidate();timer=nil;panel.orderOut(nil)}
    private func follow() {
        if AXIsProcessTrusted(){stop();NSApp.activate(ignoringOtherApps:true);return}
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:Self.settingsApp).first else{
            if ProcessInfo.processInfo.systemUptime-openedAt>Self.giveUpAfter{stop()}else{panel.orderOut(nil)}
            return
        }
        // Only list windows while System Settings is in front, since the panel has nothing to follow otherwise.
        guard app.isActive else{panel.orderOut(nil);return}
        let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        guard let settings=Self.settingsWindow(in:windows,owner:app.processIdentifier,primaryHeight:NSScreen.screens.first?.frame.maxY ?? 0) else{
            panel.orderOut(nil);return
        }
        let frame=Self.placement(settings)
        if panel.frame != frame{panel.setFrame(frame,display:true)}
        if !panel.isVisible{panel.orderFrontRegardless()}
    }
    // The owner's largest ordinary window, in AppKit's coordinates: window lists count from the top of the primary screen.
    static func settingsWindow(in windows:[[String:Any]],owner:pid_t,primaryHeight:CGFloat)->NSRect? {
        let frames=windows.compactMap{window->CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==owner,(window[kCGWindowLayer as String] as? NSNumber)?.intValue==0,
                  let bounds=window[kCGWindowBounds as String] as? [String:Any] else{return nil}
            return CGRect(dictionaryRepresentation:bounds as CFDictionary)
        }
        guard let largest=frames.filter({$0.width>Self.narrowest}).max(by:{$0.width*$0.height<$1.width*$1.height}) else{return nil}
        return NSRect(x:largest.minX,y:primaryHeight-largest.maxY,width:largest.width,height:largest.height)
    }
    // Over the bottom of the list, clear of the sidebar and the + and − buttons, leaving the list itself to drop into.
    static func placement(_ settings:NSRect)->NSRect {
        let width=min(size.width,max(narrowest,settings.width-sidebar-inset))
        return NSRect(x:settings.maxX-inset-width,y:settings.minY+aboveButtons,width:width,height:size.height)
    }
    static func previewWindow()->NSWindow {
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.backgroundColor=HomePalette.sidebar;window.contentView=AccessibilityGuideView()
        return window
    }
}

private final class AccessibilityGuidePanel:NSPanel {
    override var canBecomeKey:Bool{false}
    override var canBecomeMain:Bool{false}
}

private final class AccessibilityGuideView:NSView {
    init() {
        super.init(frame:.zero)
        let badge=RemoteSurface(HomePalette.ink,radius:14),arrow=rkSymbolView("arrow.up",13,HomePalette.canvas,.semibold)
        badge.translatesAutoresizingMaskIntoConstraints=false;arrow.translatesAutoresizingMaskIntoConstraints=false
        badge.addSubview(arrow)
        let words=rkVStack([rkLabel("Drag AirPointer into the list above",13,.semibold),rkLabel("Already listed? Just turn on its switch.",12,.regular,.secondaryLabelColor)],spacing:2)
        let top=rkHStack([badge,words],spacing:12),card=AccessibilityGuideCard()
        let column=rkVStack([top,card],spacing:12)
        rkPin(column,in:self,insets:NSEdgeInsets(top:14,left:14,bottom:14,right:14))
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant:28),badge.heightAnchor.constraint(equalToConstant:28),
            arrow.centerXAnchor.constraint(equalTo:badge.centerXAnchor),arrow.centerYAnchor.constraint(equalTo:badge.centerYAnchor),
            card.widthAnchor.constraint(equalTo:column.widthAnchor),card.heightAnchor.constraint(equalToConstant:56),
        ])
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func draw(_ dirtyRect:NSRect) {
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:16,yRadius:16)
        HomePalette.raised.setFill();shape.fill()
        HomePalette.rule.setStroke();shape.lineWidth=1;shape.stroke()
    }
}

// AirPointer itself, to pick up: dragging it carries the app's file, which the list adds.
private final class AccessibilityGuideCard:NSView,NSDraggingSource {
    private var hovered=false{didSet{if hovered != oldValue{needsDisplay=true}}}
    private var pressed=false
    init() {
        super.init(frame:.zero)
        translatesAutoresizingMaskIntoConstraints=false
        let icon=NSImageView(image:NSApp.applicationIconImage ?? NSImage());icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints=false;icon.setAccessibilityElement(false)
        let name=rkLabel("AirPointer",13,.semibold);name.setAccessibilityElement(false)
        let row=rkHStack([icon,name,rkSpacer(),rkSymbolView("line.3.horizontal",13)],spacing:12)
        rkPin(row,in:self,insets:NSEdgeInsets(top:12,left:12,bottom:12,right:16))
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:32),icon.heightAnchor.constraint(equalToConstant:32)])
        setAccessibilityElement(true);setAccessibilityRole(.image)
        setAccessibilityLabel("AirPointer. Drag this into the Accessibility list above.")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override var mouseDownCanMoveWindow:Bool{false}
    // System Settings stays in front while this is used, so the first click has to count and hovering works from outside.
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event:NSEvent){hovered=true;NSCursor.openHand.set()}
    override func mouseExited(with event:NSEvent){hovered=false;NSCursor.arrow.set()}
    override func mouseDown(with event:NSEvent){pressed=true;NSCursor.closedHand.set()}
    override func mouseUp(with event:NSEvent){pressed=false;NSCursor.openHand.set()}
    override func mouseDragged(with event:NSEvent) {
        guard pressed else{return}
        pressed=false
        let item=NSDraggingItem(pasteboardWriter:Bundle.main.bundleURL as NSURL)
        let image=NSImage(size:bounds.size)
        if let rep=bitmapImageRepForCachingDisplay(in:bounds){cacheDisplay(in:bounds,to:rep);image.addRepresentation(rep)}
        item.setDraggingFrame(bounds,contents:image)
        beginDraggingSession(with:[item],event:event,source:self).animatesToStartingPositionsOnCancelOrFail=true
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation{context == .outsideApplication ? .copy:[]}
    func ignoreModifierKeys(for session:NSDraggingSession)->Bool{true}
    override func draw(_ dirtyRect:NSRect) {
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10)
        HomePalette.canvas.setFill();shape.fill()
        if hovered{HomePalette.focusedSelection.setFill();shape.fill()}
        HomePalette.rule.setStroke();shape.lineWidth=1;shape.stroke()
    }
}
