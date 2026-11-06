import AppKit
import QuartzCore

// The menu-bar item, its popover (the everyday control surface) and a brief
// bubble that says what just happened.

struct MenuBarState:Equatable {
    enum Status:Equatable{case notConnected,connecting,needsAccess,ready,live,paused(String)}
    var status:Status = .notConnected
    var detail=""
    var speed=1.0
    var canDisconnect=false
}
enum MenuBarCommand{case toggleControl,recenter,pause,open,calibrate,disconnect,settings,quit}

private enum MenuGlyph:Equatable{case off,idle,pending,live}
private extension MenuBarState.Status {
    var running:Bool{switch self{case .live,.connecting:return true;default:return false}}
    var connected:Bool{switch self{case .notConnected,.connecting,.needsAccess:return false;default:return true}}
    var glyph:MenuGlyph{switch self{case .notConnected:return .off;case .connecting:return .pending;case .live:return .live;default:return .idle}}
    var title:String {
        switch self {
        case .notConnected:return "Not connected"
        case .connecting:return "Connecting…"
        case .needsAccess:return "Allow control"
        case .ready:return "Ready"
        case .live:return "Pointing"
        case .paused:return "Paused"
        }
    }
    var spoken:String {
        switch self {
        case .needsAccess:return "needs permission"
        case .connecting:return "connecting"
        default:return title.lowercased()
        }
    }
    // Why the pointer is still, for the aim pad caption.
    var reason:String {
        switch self {
        case .notConnected:return "AirPods not connected"
        case .connecting:return "Waiting for AirPods motion…"
        case .needsAccess:return "Allow Accessibility to move the pointer"
        case .ready:return "Ready — switch on to start"
        case .live:return ""
        case .paused(let why):
            let why=why.trimmingCharacters(in:.whitespacesAndNewlines)
            return why.isEmpty || why == "Paused" ? "Paused":why.hasPrefix("Paused") ? why:"Paused — \(why)"
        }
    }
}

// Graphite stand-in for the accent color in the slider fill.
private let menuFill=rkAdaptive("AirPointerMenuFill"){dark,contrast in dark ? NSColor(white:contrast ? 1:0.72,alpha:1):rkRGB(contrast ? 0x000000:0x1D1D1F)}

private func menuFit(_ text:String,_ width:CGFloat,_ font:NSFont)->String {
    let attributes:[NSAttributedString.Key:Any]=[.font:font]
    guard (text as NSString).size(withAttributes:attributes).width>width else{return text}
    var characters=Array(text)
    while !characters.isEmpty && ((String(characters)+"…") as NSString).size(withAttributes:attributes).width>width{characters.removeLast()}
    return String(characters).trimmingCharacters(in:.whitespaces)+"…"
}

// MARK: - Status item

final class StatusBarController:NSObject,NSPopoverDelegate {
    var onToggleControl,onRecenter,onPause,onOpen,onCalibrate,onDisconnect,onSettings,onQuit:(()->Void)?
    var onSpeedChange:((Double)->Void)?
    private let item:NSStatusItem
    private let popover=NSPopover()
    private let content=MenuBarContentController()
    private var state=MenuBarState()
    private var glyph:MenuGlyph?
    private var iconAppearance:Int?
    private var appearanceObservation:NSKeyValueObservation?
    private var closedAt:CFTimeInterval=0
    private var returnTo:NSRunningApplication?

    override init() {
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        super.init()
        popover.behavior = .transient;popover.delegate=self;popover.contentViewController=content
        content.onCommand={[weak self] in self?.run($0)}
        content.onSpeedChange={[weak self] in self?.onSpeedChange?($0)}
        if let button=item.button {
            button.target=self;button.action=#selector(clicked);button.sendAction(on:[.leftMouseUp,.rightMouseUp])
            button.imagePosition = .imageOnly
            appearanceObservation=button.observe(\.effectiveAppearance){[weak self] _,_ in DispatchQueue.main.async{self?.refreshIcon()}}
        }
        refreshIcon()
    }

    // The closed case in outline, upright as it's held to point,
    // with its pill-shaped ridge and a laser dot while live. Drawn for one
    // appearance so light and dark menu bars each get their own ink; the red
    // dot is why this can't be a template image.
    private static func iconAppearanceKey(_ appearance:NSAppearance)->Int{
        let name=appearance.bestMatch(from:[.aqua,.darkAqua,.vibrantLight,.vibrantDark,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua,
                                            .accessibilityHighContrastVibrantLight,.accessibilityHighContrastVibrantDark]) ?? .aqua
        let dark=[.darkAqua,.vibrantDark,.accessibilityHighContrastDarkAqua,.accessibilityHighContrastVibrantDark].contains(name)
        let contrast=name.rawValue.contains("HighContrast")
        return (dark ? 1:0) | (contrast ? 2:0)
    }
    static func menuBarImage(for status:MenuBarState.Status,appearance:NSAppearance)->NSImage {
        let glyph=status.glyph,key=iconAppearanceKey(appearance)
        let dark=key & 1 != 0,contrast=key & 2 != 0
        // Matches the menu bar's own glyph ink, which labelColor only reaches through vibrancy.
        let ink=NSColor(white:dark ? 1:0,alpha:glyph == .off ? 0.35:dark || contrast ? 1:0.85)
        let image=NSImage(size:NSSize(width:18,height:18),flipped:true){_ in
            appearance.performAsCurrentDrawingAppearance {
                // The mark's proportions: 0.754 as wide as tall, the ridge 47% of the height, 68% across.
                let body=NSRect(x:3.345,y:1.5,width:11.31,height:15)
                let outline=NSBezierPath(roundedRect:body,xRadius:2.83,yRadius:2.83)
                outline.lineWidth=1.5;ink.setStroke();outline.stroke()
                // Solid rather than an outlined pill, which reads as a zero at this size.
                let ridge=body.minX+body.width*0.68
                ink.setFill();NSBezierPath(roundedRect:NSRect(x:ridge-0.8,y:body.midY-3.525,width:1.6,height:7.05),xRadius:0.8,yRadius:0.8).fill()
                let dot=NSPoint(x:body.minX+body.width*0.34,y:body.midY)
                switch glyph {
                case .live:HomePalette.laser.setFill();NSBezierPath(ovalIn:NSRect(x:dot.x-2,y:dot.y-2,width:4,height:4)).fill()
                case .pending:let ring=NSBezierPath(ovalIn:NSRect(x:dot.x-1.7,y:dot.y-1.7,width:3.4,height:3.4));ring.lineWidth=1.1;ring.stroke()
                case .idle,.off:break
                }
            }
            return true
        }
        image.isTemplate=false
        return image
    }

    func showPopover() {
        guard let button=item.button,!popover.isShown else{return}
        let front=NSWorkspace.shared.frontmostApplication
        returnTo=front == NSRunningApplication.current ? nil:front
        content.apply(state)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        button.highlight(true)
        // Shown before activating, so activation never switches Spaces away from a full-screen app.
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }
    func update(_ state:MenuBarState) {
        guard state != self.state else{return}
        let statusChanged=state.status != self.state.status
        self.state=state
        if statusChanged{refreshIcon()}
        if popover.isShown{content.apply(state)}
    }
    func updatePointer(_ point:CGPoint) {
        guard popover.isShown else{return}
        content.setPointer(point)
    }

    private func refreshIcon() {
        guard let button=item.button else{return}
        let status=state.status
        let appearance=Self.iconAppearanceKey(button.effectiveAppearance)
        // AppKit can notify effectiveAppearance while snapshotting a status item.
        // Replacing its image for an equivalent palette schedules another snapshot.
        if glyph != status.glyph || iconAppearance != appearance {
            glyph=status.glyph;iconAppearance=appearance
            button.image=Self.menuBarImage(for:status,appearance:button.effectiveAppearance)
        }
        let label="AirPointer, \(status.spoken)"
        if button.accessibilityLabel() != label{button.setAccessibilityLabel(label);button.toolTip="AirPointer — \(status.title)"}
    }
    @objc private func clicked() {
        if popover.isShown{popover.performClose(nil)}
        else if CACurrentMediaTime()-closedAt>0.3{showPopover()}
    }
    private func run(_ command:MenuBarCommand) {
        switch command {
        case .toggleControl:onToggleControl?()
        case .recenter:onRecenter?()
        case .pause:onPause?()
        case .open:dismiss(then:onOpen)
        case .calibrate:dismiss(then:onCalibrate)
        case .disconnect:onDisconnect?()
        case .settings:dismiss(then:onSettings)
        case .quit:dismiss(then:onQuit ?? {NSApp.terminate(nil)})
        }
    }
    // Closes first so the window it opens comes up in front, and keeps focus here.
    private func dismiss(then action:(()->Void)?) {
        returnTo=nil;popover.close();item.button?.highlight(false)
        action?()
    }
    func popoverDidShow(_ notification:Notification){item.button?.highlight(true)}
    func popoverWillClose(_ notification:Notification){closedAt=CACurrentMediaTime()}
    func popoverDidClose(_ notification:Notification) {
        closedAt=CACurrentMediaTime();item.button?.highlight(false)
        // Hand focus back to the previous app so its keys keep working.
        if let app=returnTo,NSApp.isActive,!app.isTerminated{_=app.activate(from:.current,options:[])}
        returnTo=nil
    }
}

// MARK: - Popover content

// Everything inside the popover; it needs no status item, so it can be
// shown on its own for previews and checks.
final class MenuBarContentController:NSViewController {
    static let width:CGFloat=320
    var onCommand:((MenuBarCommand)->Void)?
    var onSpeedChange:((Double)->Void)?
    private(set) var state:MenuBarState?
    private let chip=StatusChip()
    private let power=InkSwitch()
    private let detail=rkLabel("",12,.regular,.secondaryLabelColor)
    private let pad=AimPadView()
    private let recenter=RemoteButton("Recenter",style:.secondary,symbol:"scope",height:32)
    private let pause=RemoteButton("Pause",style:.secondary,hint:PointerShortcut.current.label,symbol:"pause.fill",height:32)
    private let speed=NSSlider(value:1,minValue:0.4,maxValue:2.4,target:nil,action:nil)
    private var powerHeld:CFTimeInterval=0,speedHeld:CFTimeInterval=0
    private var layoutKey=""
    private var resync:DispatchWorkItem?
    private let inner=MenuBarContentController.width-32
    private let body=NSView()
    private var menuRows:[MenuRow]=[]

    override func loadView() {
        // The root carries NSViewController's preferredContentSize constraints and
        // the popover's own sizing, so the content sizes itself in a top-anchored body.
        let root=RemoteFlipped(frame:NSRect(x:0,y:0,width:Self.width,height:600))
        body.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo:root.topAnchor),body.leadingAnchor.constraint(equalTo:root.leadingAnchor),
            body.widthAnchor.constraint(equalToConstant:Self.width),
        ])

        let title=rkLabel("AirPointer",15,.semibold)
        title.setContentCompressionResistancePriority(.required,for:.horizontal)
        power.setAccessibilityLabel("Pointer control")
        power.onChange={[weak self] _ in self?.hold(\.powerHeld);self?.onCommand?(.toggleControl)}
        let header=rkHStack([title,chip,rkSpacer(),power],spacing:8)
        header.setCustomSpacing(10,after:title)

        pad.cornerRadius=10;pad.setAccessibilityElement(true);pad.setAccessibilityRole(.image)
        pad.heightAnchor.constraint(equalTo:pad.widthAnchor,multiplier:10.0/16).isActive=true

        recenter.target=self;recenter.action=#selector(recenterPressed)
        pause.target=self;pause.action=#selector(pausePressed)
        let buttons=rkHStack([recenter,pause],spacing:8);buttons.distribution = .fillEqually

        speed.target=self;speed.action=#selector(speedChanged);speed.isContinuous=true
        speed.trackFillColor=menuFill;speed.setAccessibilityLabel("Pointer speed")
        speed.setContentHuggingPriority(.init(1),for:.horizontal)
        let slow=rkLabel("Slow",12,.regular,.secondaryLabelColor),fast=rkLabel("Fast",12,.regular,.secondaryLabelColor)
        for label in [slow,fast]{label.setContentHuggingPriority(.required,for:.horizontal);label.setAccessibilityElement(false)}
        let speedRow=rkHStack([slow,speed,fast],spacing:10)

        let top=rkVStack([header,detail],spacing:2)
        for view in top.arrangedSubviews{view.widthAnchor.constraint(equalTo:top.widthAnchor).isActive=true}
        let column=rkVStack([top,pad,buttons,speedRow],spacing:0)
        for view in column.arrangedSubviews{view.widthAnchor.constraint(equalTo:column.widthAnchor).isActive=true}
        column.setCustomSpacing(12,after:top);column.setCustomSpacing(8,after:pad)
        column.setCustomSpacing(16,after:buttons)
        body.addSubview(column)

        let rule=RemoteRule();rule.translatesAutoresizingMaskIntoConstraints=false;body.addSubview(rule)
        let quitRule=RemoteRule();quitRule.translatesAutoresizingMaskIntoConstraints=false
        menuRows=[
            MenuRow("Open AirPointer",.open,target:self),MenuRow("Calibrate…",.calibrate,target:self),
            MenuRow("Disconnect",.disconnect,target:self),MenuRow("Settings…",.settings,key:",",target:self),
            MenuRow("Quit AirPointer",.quit,key:"q",target:self),
        ]
        let footer=rkVStack(Array(menuRows[0..<4])+[quitRule,menuRows[4]],spacing:0)
        for row in menuRows{row.widthAnchor.constraint(equalTo:footer.widthAnchor).isActive=true}
        footer.setCustomSpacing(4,after:menuRows[3]);footer.setCustomSpacing(4,after:quitRule)
        body.addSubview(footer)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo:body.topAnchor,constant:16),
            column.leadingAnchor.constraint(equalTo:body.leadingAnchor,constant:16),
            column.trailingAnchor.constraint(equalTo:body.trailingAnchor,constant:-16),
            rule.topAnchor.constraint(equalTo:column.bottomAnchor,constant:12),
            rule.leadingAnchor.constraint(equalTo:body.leadingAnchor,constant:16),
            rule.trailingAnchor.constraint(equalTo:body.trailingAnchor,constant:-16),
            quitRule.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:8),
            quitRule.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-8),
            footer.topAnchor.constraint(equalTo:rule.bottomAnchor,constant:6),
            footer.leadingAnchor.constraint(equalTo:body.leadingAnchor,constant:8),
            footer.trailingAnchor.constraint(equalTo:body.trailingAnchor,constant:-8),
            footer.bottomAnchor.constraint(equalTo:body.bottomAnchor,constant:-8),
        ])
        view=root
    }
    // A row clicked just before the popover closed would otherwise reopen highlighted.
    override func viewWillAppear(){super.viewWillAppear();for row in menuRows{row.hovering=false}}

    // Diffs against what is on screen, so it is cheap to call on every tick.
    func apply(_ state:MenuBarState){apply(state,force:false)}
    func setPointer(_ point:CGPoint){if isViewLoaded && pad.point != point{pad.point=point}}

    private func apply(_ state:MenuBarState,force:Bool) {
        loadViewIfNeeded()
        let old=self.state
        guard force || state != old else{return}
        self.state=state
        let status=state.status,now=CACurrentMediaTime()
        if force || old?.status != status {
            let live=status == .live
            chip.set(status.title,live:live,dot:status.connected)
            if pad.live != live{pad.live=live}
            let reason=status.reason
            pad.caption=menuFit(reason,inner-24,.systemFont(ofSize:11,weight:.medium))
            pad.toolTip=reason.isEmpty ? nil:reason
            pad.setAccessibilityLabel(live ? "Pointer preview, live":"Pointer preview. \(reason)")
            // A still pointer rests at the center; a paused one stays where it was aimed.
            if !live{if case .paused=status{}else{pad.point=CGPoint(x:0.5,y:0.5)}}
            if recenter.isEnabled != status.connected{recenter.isEnabled=status.connected}
            if pause.isEnabled != status.running{pause.isEnabled=status.running}
        }
        // The key chip is for pausing, so it shows only while there is something to pause.
        let hint=status.running ? PointerShortcut.current.label:nil
        if pause.hint != hint{pause.hint=hint}
        if now>=powerHeld && power.isOn != status.running{power.setOn(status.running,animated:old != nil)}
        rkSetText(detail,state.detail)
        if detail.toolTip != state.detail{detail.toolTip=state.detail.isEmpty ? nil:state.detail}
        if detail.isHidden != state.detail.isEmpty{detail.isHidden=state.detail.isEmpty}
        if now>=speedHeld && abs(speed.doubleValue-state.speed)>0.0001{speed.doubleValue=state.speed}
        let spoken=String(format:"%.1f times normal",speed.doubleValue)
        if speed.accessibilityValueDescription() != spoken{speed.setAccessibilityValueDescription(spoken)}
        // Disconnect is there only while the closed case is connected.
        if let row=menuRows.first(where:{$0.command == .disconnect}),row.isHidden == state.canDisconnect{row.isHidden = !state.canDisconnect}
        let key="\(state.detail.isEmpty)|\(state.canDisconnect)"
        if key != layoutKey{layoutKey=key;body.layoutSubtreeIfNeeded();preferredContentSize=NSSize(width:Self.width,height:ceil(body.fittingSize.height))}
    }
    // A control the user just changed keeps its new value briefly, so a
    // state tick that predates the change can't flick it back.
    private func hold(_ field:ReferenceWritableKeyPath<MenuBarContentController,CFTimeInterval>) {
        self[keyPath:field]=CACurrentMediaTime()+0.8
        resync?.cancel()
        let work=DispatchWorkItem{[weak self] in
            guard let self,let state=self.state else{return}
            self.apply(state,force:true)
        }
        resync=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.85,execute:work)
    }
    @objc private func recenterPressed(){onCommand?(.recenter)}
    @objc private func pausePressed(){onCommand?(.pause)}
    @objc private func speedChanged(){hold(\.speedHeld);onSpeedChange?(speed.doubleValue)}
    @objc fileprivate func rowPressed(_ sender:MenuRow){onCommand?(sender.command)}
}

// An ink switch: NSSwitch can only draw in the system accent color.
final class InkSwitch:NSView {
    var onChange:((Bool)->Void)?
    private(set) var isOn=false
    var isEnabled=true{didSet{if isEnabled != oldValue{needsDisplay=true}}}
    @objc dynamic var progress:CGFloat=0{didSet{needsDisplay=true}}
    init(){super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false;setContentHuggingPriority(.required,for:.horizontal)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override class func defaultAnimation(forKey key:NSAnimatablePropertyKey)->Any? {
        key == "progress" ? CABasicAnimation():super.defaultAnimation(forKey:key)
    }
    override var intrinsicContentSize:NSSize{NSSize(width:40,height:24)}
    override var acceptsFirstResponder:Bool{isEnabled}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    func setOn(_ on:Bool,animated:Bool) {
        guard on != isOn else{return}
        isOn=on
        if animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup{context in context.duration=0.16;context.timingFunction=CAMediaTimingFunction(name:.easeOut);animator().progress=on ? 1:0}
        } else{progress=on ? 1:0}
        NSAccessibility.post(element:self,notification:.valueChanged)
    }
    private func toggle(){guard isEnabled else{return};setOn(!isOn,animated:true);onChange?(isOn)}
    override func mouseDown(with event:NSEvent){toggle()}
    override func keyDown(with event:NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36{toggle()}else{super.keyDown(with:event)}
    }
    override var focusRingMaskBounds:NSRect{bounds}
    override func drawFocusRingMask(){NSBezierPath(roundedRect:bounds,xRadius:bounds.height/2,yRadius:bounds.height/2).fill()}
    override func draw(_ dirtyRect:NSRect) {
        let match=effectiveAppearance.bestMatch(from:[.aqua,.darkAqua,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua])
        let dark=match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        context.saveGState();defer{context.restoreGState()}
        if !isEnabled{context.setAlpha(0.4);context.beginTransparencyLayer(auxiliaryInfo:nil)}
        let track=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:bounds.height/2-0.5,yRadius:bounds.height/2-0.5)
        HomePalette.track.setFill();track.fill()
        HomePalette.ink.withAlphaComponent(progress).setFill();track.fill()
        if match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua{HomePalette.rule.setStroke();track.lineWidth=1;track.stroke()}
        let side=bounds.height-4
        let knob=NSRect(x:2+(bounds.width-4-side)*progress,y:2,width:side,height:side)
        NSGraphicsContext.saveGraphicsState()
        if !dark{let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.22);shadow.shadowBlurRadius=2;shadow.shadowOffset=NSSize(width:0,height:-1);shadow.set()}
        (dark && progress>0.5 ? HomePalette.canvas:NSColor(white:dark ? 0.92:1,alpha:1)).setFill()
        NSBezierPath(ovalIn:knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        if !isEnabled{context.endTransparencyLayer()}
    }
    override func isAccessibilityElement()->Bool{true}
    override func accessibilityRole()->NSAccessibility.Role?{.checkBox}
    override func accessibilitySubrole()->NSAccessibility.Subrole?{.switch}
    override func accessibilityValue()->Any?{NSNumber(value:isOn ? 1:0)}
    override func isAccessibilityEnabled()->Bool{isEnabled}
    override func accessibilityPerformPress()->Bool{guard isEnabled else{return false};toggle();return true}
}

// A menu-style row: left-aligned title, optional shortcut, gray hover.
private final class MenuRow:NSButton {
    let command:MenuBarCommand
    private let shortcut:String?
    var hovering=false{didSet{if hovering != oldValue{needsDisplay=true}}}
    private var area:NSTrackingArea?
    init(_ title:String,_ command:MenuBarCommand,key:String?=nil,target:MenuBarContentController) {
        self.command=command;shortcut=key.map{"⌘"+$0.uppercased()}
        super.init(frame:.zero)
        self.title=title;isBordered=false;setButtonType(.momentaryPushIn);translatesAutoresizingMaskIntoConstraints=false
        self.target=target;action=#selector(MenuBarContentController.rowPressed(_:))
        if let key{keyEquivalent=key;keyEquivalentModifierMask = .command}
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override var intrinsicContentSize:NSSize{NSSize(width:NSView.noIntrinsicMetric,height:24)}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area{removeTrackingArea(area)}
        let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(next);area=next
    }
    override func mouseEntered(with event:NSEvent){hovering=true}
    override func mouseExited(with event:NSEvent){hovering=false}
    override var focusRingMaskBounds:NSRect{bounds}
    override func drawFocusRingMask(){NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()}
    override func draw(_ dirtyRect:NSRect) {
        let pressed=cell?.isHighlighted == true
        if isEnabled && (hovering || pressed) {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.14:0.08).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()
        }
        let font=NSFont.systemFont(ofSize:13)
        let size=(title as NSString).size(withAttributes:[.font:font])
        let y=floor((bounds.height-size.height)/2)
        var trailing=bounds.width-8
        if let shortcut {
            let width=(shortcut as NSString).size(withAttributes:[.font:font]).width
            trailing-=width
            (shortcut as NSString).draw(at:NSPoint(x:trailing,y:y),withAttributes:[.font:font,.foregroundColor:NSColor.tertiaryLabelColor])
            trailing-=12
        }
        let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in:NSRect(x:8,y:y,width:max(0,trailing-8),height:size.height),
                                 withAttributes:[.font:font,.foregroundColor:isEnabled ? NSColor.labelColor:.tertiaryLabelColor,.paragraphStyle:style])
    }
}

// MARK: - HUD

// The bubble itself: a dark capsule with white text, an optional symbol
// and a laser dot while live.
final class ControlHUDView:NSView {
    private(set) var text=""
    private(set) var symbol:String?
    private(set) var live=false
    var maxWidth:CGFloat=480{didSet{invalidateIntrinsicContentSize()}}
    private let font=NSFont.systemFont(ofSize:15,weight:.semibold)
    private var image:NSImage?
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityElement(false)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func set(_ text:String,symbol:String?,live:Bool) {
        guard text != self.text || symbol != self.symbol || live != self.live else{return}
        if symbol != self.symbol{image=symbol.flatMap{rkSymbol($0,15,.semibold)?.withSymbolConfiguration(.init(paletteColors:[.white]))}}
        self.text=text;self.symbol=symbol;self.live=live
        needsDisplay=true;invalidateIntrinsicContentSize()
    }
    private var leading:CGFloat{(live ? 16:0)+(image.map{$0.size.width+8} ?? 0)}
    override var intrinsicContentSize:NSSize {
        let width=ceil((text as NSString).size(withAttributes:[.font:font]).width)+leading+40
        return NSSize(width:min(maxWidth,max(96,width)),height:40)
    }
    override func draw(_ dirtyRect:NSRect) {
        let solid=NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:(bounds.height-1)/2,yRadius:(bounds.height-1)/2)
        NSColor(white:0,alpha:solid ? 0.94:0.82).setFill();shape.fill()
        NSColor(white:1,alpha:solid ? 0.45:0.14).setStroke();shape.lineWidth=1;shape.stroke()
        let textWidth=ceil((text as NSString).size(withAttributes:[.font:font]).width)
        var x=max(20,floor((bounds.width-textWidth-leading)/2))
        if live {
            let dot=NSRect(x:x,y:bounds.midY-4,width:8,height:8)
            HomePalette.laser.withAlphaComponent(0.3).setFill();NSBezierPath(ovalIn:dot.insetBy(dx:-3,dy:-3)).fill()
            HomePalette.laser.setFill();NSBezierPath(ovalIn:dot).fill()
            x+=16
        }
        if let image {
            image.draw(in:NSRect(x:x,y:floor(bounds.midY-image.size.height/2),width:image.size.width,height:image.size.height))
            x+=image.size.width+8
        }
        let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail
        let height=ceil(font.ascender-font.descender)
        (text as NSString).draw(in:NSRect(x:x,y:floor((bounds.height-height)/2),width:max(0,bounds.width-x-20),height:height),
                                withAttributes:[.font:font,.foregroundColor:NSColor.white,.paragraphStyle:style])
    }
}

private final class HUDPanel:NSPanel {
    override var canBecomeKey:Bool{false}
    override var canBecomeMain:Bool{false}
}

// A brief, click-through status bubble near the bottom of the screen that
// floats over full-screen apps and never takes focus.
final class ControlHUD {
    private let panel=HUDPanel(contentRect:NSRect(x:0,y:0,width:160,height:40),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
    private let bubble=ControlHUDView()
    private var generation=0
    private var hold:DispatchWorkItem?
    init() {
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.ignoresMouseEvents=true
        panel.level = .statusBar;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.isExcludedFromWindowsMenu=true;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false
        panel.animationBehavior = .none;panel.alphaValue=0
        panel.appearance=NSAppearance(named:.darkAqua);panel.contentView=bubble
    }
    func show(_ text:String,symbol:String?=nil,live:Bool=false,on screen:NSScreen?) {
        guard let screen=screen ?? NSScreen.main ?? NSScreen.screens.first else{return}
        generation+=1;hold?.cancel()
        let area=screen.visibleFrame
        bubble.maxWidth=min(480,area.width-64);bubble.set(text,symbol:symbol,live:live)
        let size=bubble.intrinsicContentSize
        let frame=NSRect(x:round(area.midX-size.width/2),y:round(area.minY+72),width:size.width,height:size.height)
        let showing=panel.isVisible && panel.alphaValue>0.01
        let still=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if showing {
            // Replace in place without fading from zero; new animations supersede a slide or fade in flight.
            NSAnimationContext.runAnimationGroup{context in context.duration=still ? 0:0.15;panel.animator().setFrame(frame,display:true)}
            NSAnimationContext.runAnimationGroup{context in context.duration=0.15;panel.animator().alphaValue=1}
        } else {
            panel.setFrame(still ? frame:frame.offsetBy(dx:0,dy:-8),display:true)
            panel.alphaValue=0;panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup{context in
                context.duration=0.15;context.timingFunction=CAMediaTimingFunction(name:.easeOut)
                panel.animator().alphaValue=1
                if !still{panel.animator().setFrame(frame,display:true)}
            }
        }
        panel.invalidateShadow()
        let generation=self.generation
        let work=DispatchWorkItem{[weak self] in self?.fadeOut(generation)}
        hold=work;DispatchQueue.main.asyncAfter(deadline:.now()+(showing ? 1.2:1.35),execute:work)
        NSAccessibility.post(element:NSApp as Any,notification:.announcementRequested,
                             userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])
    }
    private func fadeOut(_ generation:Int) {
        guard generation == self.generation else{return}
        NSAnimationContext.runAnimationGroup({context in
            context.duration=0.3;context.timingFunction=CAMediaTimingFunction(name:.easeIn)
            panel.animator().alphaValue=0
        },completionHandler:{[weak self] in
            guard let self,generation == self.generation else{return}
            self.panel.orderOut(nil)
        })
    }
}
