import AppKit
import QuartzCore

// Shared look for every AirPointer surface: grayscale surfaces and graphite
// ink, with one laser red reserved for "live" (the pointer dot, the pointing
// status and recording in progress). Text stays on system label colors so
// Increase Contrast and the dark appearance keep behaving natively.

// MARK: - Palette

func rkRGB(_ hex:UInt32,_ alpha:CGFloat=1)->NSColor {
    NSColor(srgbRed:CGFloat((hex>>16)&0xFF)/255,green:CGFloat((hex>>8)&0xFF)/255,blue:CGFloat(hex&0xFF)/255,alpha:alpha)
}
func rkAdaptive(_ name:String,_ resolve:@escaping (_ dark:Bool,_ contrast:Bool)->NSColor)->NSColor {
    NSColor(name:name){appearance in
        let match=appearance.bestMatch(from:[.aqua,.darkAqua,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua])
        return resolve(match == .darkAqua || match == .accessibilityHighContrastDarkAqua,match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua)
    }
}
enum HomePalette {
    static let canvas=rkAdaptive("AirPointerCanvas"){dark,_ in rkRGB(dark ? 0x1C1C1E:0xFFFFFF)}
    static let sidebar=rkAdaptive("AirPointerSidebar"){dark,_ in rkRGB(dark ? 0x232325:0xF2F2F4)}
    static let raised=rkAdaptive("AirPointerRaised"){dark,_ in rkRGB(dark ? 0x2A2A2D:0xF5F5F7)}
    static let rule=rkAdaptive("AirPointerRule"){dark,contrast in NSColor(white:dark ? 1:0,alpha:contrast ? 0.45:dark ? 0.12:0.1)}
    static let track=rkAdaptive("AirPointerTrack"){dark,contrast in NSColor(white:dark ? 1:0,alpha:contrast ? 0.35:dark ? 0.16:0.1)}
    static let focusedSelection=rkAdaptive("AirPointerFocusedSelection"){dark,contrast in NSColor(white:dark ? 1:0,alpha:contrast ? 0.24:dark ? 0.12:0.1)}
    static let ink=rkAdaptive("AirPointerInk"){dark,contrast in contrast ? rkRGB(dark ? 0xFFFFFF:0x000000):rkRGB(dark ? 0xF2F2F2:0x1D1D1F)}
    // The stage behind the case render: dark in both appearances so the white
    // case stands out, and still lighter than `screen` so the pad reads on it.
    static let stage=rkAdaptive("AirPointerStage"){_,_ in rkRGB(0x2A2A2D)}
    static let control=rkAdaptive("AirPointerControl"){dark,contrast in NSColor(white:dark ? 1:0,alpha:contrast ? 0.24:dark ? 0.13:0.075)}
    // The dark miniature display the live pointer is drawn on.
    static let screen=rkAdaptive("AirPointerScreen"){dark,_ in rkRGB(dark ? 0x0B0B0C:0x141416)}
    // Live only: never a button, border or decoration.
    static let laser=rkAdaptive("AirPointerLaser"){dark,_ in rkRGB(dark ? 0xFF453A:0xFF3B30)}
}

// MARK: - Text

func rkSymbol(_ name:String,_ size:CGFloat,_ weight:NSFont.Weight = .regular)->NSImage? {
    let image=NSImage(systemSymbolName:name,accessibilityDescription:nil) ?? NSImage(systemSymbolName:"circle",accessibilityDescription:nil)
    return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:size,weight:weight))
}
func rkSymbolView(_ name:String,_ size:CGFloat,_ color:NSColor? = .secondaryLabelColor,_ weight:NSFont.Weight = .regular)->NSImageView {
    let view=NSImageView();view.image=rkSymbol(name,size,weight);view.contentTintColor=color
    view.setAccessibilityElement(false)
    view.setContentHuggingPriority(.required,for:.horizontal);view.setContentCompressionResistancePriority(.required,for:.horizontal)
    return view
}
func rkLabel(_ text:String,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular,_ color:NSColor = .labelColor)->NSTextField {
    let field=NSTextField(labelWithString:text)
    field.font = .systemFont(ofSize:size,weight:weight);field.textColor=color;field.lineBreakMode = .byTruncatingTail
    return field
}
// A wrapping label that tracks its own width, so stack views size it correctly.
final class RemoteWrappingLabel:NSTextField {
    override func setFrameSize(_ size:NSSize) {
        super.setFrameSize(size)
        if abs(preferredMaxLayoutWidth-size.width)>0.5{preferredMaxLayoutWidth=size.width;invalidateIntrinsicContentSize()}
    }
}
func rkWrap(_ text:String,_ size:CGFloat=13,_ color:NSColor = .secondaryLabelColor,_ weight:NSFont.Weight = .regular,align:NSTextAlignment = .natural)->RemoteWrappingLabel {
    let field=RemoteWrappingLabel(wrappingLabelWithString:text)
    field.font = .systemFont(ofSize:size,weight:weight);field.textColor=color;field.alignment=align
    field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    return field
}
// Large titles get tight tracking, like the system's display type.
func rkTitle(_ text:String,_ size:CGFloat=26,align:NSTextAlignment = .natural)->RemoteWrappingLabel {
    let field=rkWrap(text,size,.labelColor,.semibold,align:align)
    field.font = .systemFont(ofSize:size,weight:size>=24 ? .bold:.semibold)
    return field
}
func rkSetText(_ field:NSTextField,_ text:String){if field.stringValue != text{field.stringValue=text}}

// MARK: - Layout

final class RemoteFlipped:NSView{override var isFlipped:Bool{true}}
final class RemoteSurface:NSView {
    var color:NSColor{didSet{needsDisplay=true}}
    var radius:CGFloat{didSet{needsDisplay=true}}
    init(_ color:NSColor,radius:CGFloat=0){self.color=color;self.radius=radius;super.init(frame:.zero)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func draw(_ dirtyRect:NSRect) {
        color.setFill()
        if radius>0{NSBezierPath(roundedRect:bounds,xRadius:radius,yRadius:radius).fill()}else{dirtyRect.fill()}
    }
}
// A one-pixel hairline at any backing scale.
final class RemoteRule:NSView {
    override var intrinsicContentSize:NSSize{NSSize(width:NSView.noIntrinsicMetric,height:1)}
    override func viewDidChangeBackingProperties(){super.viewDidChangeBackingProperties();needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        HomePalette.rule.setFill()
        NSRect(x:0,y:0,width:bounds.width,height:1/(window?.backingScaleFactor ?? 2)).fill()
    }
}
func rkVStack(_ views:[NSView]=[],spacing:CGFloat=8,align:NSLayoutConstraint.Attribute = .leading)->NSStackView {
    let stack=NSStackView(views:views);stack.orientation = .vertical;stack.alignment=align;stack.spacing=spacing
    stack.translatesAutoresizingMaskIntoConstraints=false
    return stack
}
func rkHStack(_ views:[NSView]=[],spacing:CGFloat=8)->NSStackView {
    let stack=NSStackView(views:views);stack.orientation = .horizontal;stack.alignment = .centerY;stack.spacing=spacing
    stack.translatesAutoresizingMaskIntoConstraints=false
    return stack
}
func rkSpacer()->NSView {
    let view=NSView();view.translatesAutoresizingMaskIntoConstraints=false
    view.setContentHuggingPriority(.init(1),for:.horizontal);view.setContentHuggingPriority(.init(1),for:.vertical)
    view.setContentCompressionResistancePriority(.init(1),for:.horizontal);view.setContentCompressionResistancePriority(.init(1),for:.vertical)
    return view
}
func rkPin(_ view:NSView,in parent:NSView,insets:NSEdgeInsets=NSEdgeInsetsZero) {
    view.translatesAutoresizingMaskIntoConstraints=false;parent.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo:parent.topAnchor,constant:insets.top),
        view.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-insets.bottom),
        view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:insets.left),
        view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-insets.right),
    ])
}

// MARK: - Buttons

// One drawn button for every surface: ink primary, quiet gray secondary and a
// borderless tertiary. An optional key chip names the keyboard shortcut.
final class RemoteButton:NSButton {
    enum Style{case primary,secondary,tertiary}
    var style:Style{didSet{needsDisplay=true;invalidateIntrinsicContentSize()}}
    var hint:String?{didSet{needsDisplay=true;invalidateIntrinsicContentSize()}}
    var symbolName:String?{didSet{needsDisplay=true;invalidateIntrinsicContentSize()}}
    var height:CGFloat{didSet{invalidateIntrinsicContentSize()}}
    var fontSize:CGFloat{didSet{needsDisplay=true;invalidateIntrinsicContentSize()}}
    private var hovering=false{didSet{if hovering != oldValue{needsDisplay=true}}}
    private var area:NSTrackingArea?

    init(_ title:String,style:Style = .primary,hint:String?=nil,symbol:String?=nil,height:CGFloat=44,target:AnyObject?=nil,action:Selector?=nil) {
        self.style=style;self.hint=hint;self.symbolName=symbol;self.height=height;fontSize=height>=40 ? 15:13
        super.init(frame:.zero)
        self.title=title;self.target=target;self.action=action
        isBordered=false;focusRingType = .none;translatesAutoresizingMaskIntoConstraints=false
        setButtonType(.momentaryPushIn)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override var title:String{didSet{setAccessibilityLabel(title);needsDisplay=true;invalidateIntrinsicContentSize()}}
    private var titleFont:NSFont{.systemFont(ofSize:fontSize,weight:style == .tertiary ? .medium:.semibold)}
    private var hintFont:NSFont{.monospacedSystemFont(ofSize:11,weight:.medium)}
    private var hintWidth:CGFloat{hint.map{($0 as NSString).size(withAttributes:[.font:hintFont]).width+12} ?? 0}
    override var intrinsicContentSize:NSSize {
        let text=(title as NSString).size(withAttributes:[.font:titleFont]).width
        let icon:CGFloat=symbolName == nil ? 0:fontSize+6
        let pad:CGFloat=style == .tertiary ? 20:height>=40 ? 40:28
        return NSSize(width:ceil(text+icon+pad+(hint == nil ? 0:hintWidth+10)),height:height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area{removeTrackingArea(area)}
        let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(next);area=next
    }
    override func mouseEntered(with event:NSEvent){super.mouseEntered(with:event);hovering=true}
    override func mouseExited(with event:NSEvent){super.mouseExited(with:event);hovering=false}
    override func viewDidHide(){super.viewDidHide();hovering=false}
    override func becomeFirstResponder()->Bool{let accepted=super.becomeFirstResponder();needsDisplay=true;return accepted}
    override func resignFirstResponder()->Bool{let accepted=super.resignFirstResponder();needsDisplay=true;return accepted}
    override func draw(_ dirtyRect:NSRect) {
        let pressed=cell?.isHighlighted == true
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:min(10,bounds.height/2-1),yRadius:min(10,bounds.height/2-1))
        var text=NSColor.labelColor
        switch style {
        case .primary:
            if isEnabled {
                HomePalette.ink.setFill();shape.fill()
                if pressed || hovering{NSColor(white:0.5,alpha:pressed ? 0.24:0.1).setFill();shape.fill()}
                text=HomePalette.canvas
            } else{HomePalette.control.setFill();shape.fill();text = .tertiaryLabelColor}
        case .secondary:
            HomePalette.control.setFill();shape.fill()
            if isEnabled && (pressed || hovering){NSColor.labelColor.withAlphaComponent(pressed ? 0.1:0.04).setFill();shape.fill()}
            if !isEnabled{text = .tertiaryLabelColor}
        case .tertiary:
            if isEnabled && (pressed || hovering){NSColor.labelColor.withAlphaComponent(pressed ? 0.1:0.055).setFill();shape.fill()}
            if !isEnabled{text = .tertiaryLabelColor}
        }
        let titleSize=(title as NSString).size(withAttributes:[.font:titleFont])
        let icon:CGFloat=symbolName == nil ? 0:fontSize+6
        let reserved=hint == nil ? 0:hintWidth+10
        var x=floor((bounds.width-titleSize.width-icon)/2)
        if hint != nil{x=min(x,bounds.width-reserved-titleSize.width-icon-14)}
        x=max(12,x)
        if let symbolName,let image=rkSymbol(symbolName,fontSize-1,.semibold)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[text])) {
            let size=image.size,rect=NSRect(x:x,y:floor((bounds.height-size.height)/2),width:size.width,height:size.height)
            image.draw(in:rect);x+=icon
        }
        let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail
        let rect=NSRect(x:x,y:floor((bounds.height-titleSize.height)/2)+1,width:min(titleSize.width+2,bounds.width-x-reserved-8),height:titleSize.height)
        (title as NSString).draw(in:rect,withAttributes:[.font:titleFont,.foregroundColor:text,.paragraphStyle:style])
        if let hint {
            let size=(hint as NSString).size(withAttributes:[.font:hintFont])
            let chip=NSRect(x:bounds.width-hintWidth-12,y:floor((bounds.height-size.height-4)/2),width:hintWidth,height:size.height+4)
            let path=NSBezierPath(roundedRect:chip,xRadius:5,yRadius:5);path.lineWidth=1
            text.withAlphaComponent(0.35).setStroke();path.stroke()
            (hint as NSString).draw(at:NSPoint(x:chip.minX+6,y:chip.minY+2),withAttributes:[.font:hintFont,.foregroundColor:text.withAlphaComponent(0.8)])
        }
        if window?.firstResponder === self && NSApp.isActive {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring=NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:2),xRadius:8,yRadius:8);ring.lineWidth=2;ring.stroke()
        }
    }
    override func accessibilityLabel()->String?{hint.map{"\(title), \($0)"} ?? title}
}

// A standalone keyboard shortcut chip: fn ⌃, Space, ⌘R.
final class KeyCap:NSView {
    var text:String{didSet{needsDisplay=true;invalidateIntrinsicContentSize()}}
    var color:NSColor = .secondaryLabelColor{didSet{needsDisplay=true}}
    private let font=NSFont.monospacedSystemFont(ofSize:11,weight:.medium)
    init(_ text:String){self.text=text;super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false;setAccessibilityElement(false)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override var intrinsicContentSize:NSSize {
        let size=(text as NSString).size(withAttributes:[.font:font])
        return NSSize(width:ceil(size.width)+12,height:ceil(size.height)+4)
    }
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:5,yRadius:5);path.lineWidth=1
        color.withAlphaComponent(0.45).setStroke();path.stroke()
        (text as NSString).draw(at:NSPoint(x:6,y:2),withAttributes:[.font:font,.foregroundColor:color])
    }
}

// MARK: - Status

// A capsule with a dot: ink when connected, laser red when live.
final class StatusChip:NSView {
    private(set) var text=""
    private(set) var live=false
    private var dot=true
    private let font=NSFont.systemFont(ofSize:12,weight:.medium)
    init(){super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func set(_ text:String,live:Bool=false,dot:Bool=true) {
        guard text != self.text || live != self.live || dot != self.dot else{return}
        self.text=text;self.live=live;self.dot=dot
        setAccessibilityLabel(text);needsDisplay=true;invalidateIntrinsicContentSize()
    }
    override func isAccessibilityElement()->Bool{true}
    override func accessibilityRole()->NSAccessibility.Role?{.staticText}
    override var intrinsicContentSize:NSSize {
        let size=(text as NSString).size(withAttributes:[.font:font])
        return NSSize(width:ceil(size.width)+(dot ? 34:24),height:26)
    }
    override func draw(_ dirtyRect:NSRect) {
        HomePalette.control.setFill()
        NSBezierPath(roundedRect:bounds,xRadius:bounds.height/2,yRadius:bounds.height/2).fill()
        var x:CGFloat=12
        if dot {
            let rect=NSRect(x:x,y:bounds.midY-3.5,width:7,height:7)
            if live{HomePalette.laser.withAlphaComponent(0.25).setFill();NSBezierPath(ovalIn:rect.insetBy(dx:-3,dy:-3)).fill()}
            (live ? HomePalette.laser:HomePalette.ink).setFill();NSBezierPath(ovalIn:rect).fill()
            x+=14
        }
        let size=(text as NSString).size(withAttributes:[.font:font])
        (text as NSString).draw(at:NSPoint(x:x,y:floor((bounds.height-size.height)/2)),withAttributes:[.font:font,.foregroundColor:NSColor.labelColor])
    }
}

// MARK: - Connecting the case

enum CaseStep:Equatable {case closed,opening,open,close,turn,point}

// The lid frames and the upright pose share one camera, so every step draws
// in the same rect and the case never jumps between them.
struct CaseStepArt {
    let lid:[NSImage]
    let front:NSImage
    static let shared:CaseStepArt? = {
        guard let resources=Bundle.main.resourceURL,
              let front=NSImage(contentsOf:resources.appendingPathComponent("CaseFront.png")) else{return nil}
        let lid=(0..<12).compactMap{NSImage(contentsOf:resources.appendingPathComponent(String(format:"CaseLid-%02d.png",$0)))}
        return lid.count==12 ? CaseStepArt(lid:lid,front:front):nil
    }()
}

// A progress ring: the track, then an arc from the top going clockwise.
func rkDrawRing(center c:NSPoint,radius r:CGFloat,progress:CGFloat,track:NSColor,arc color:NSColor) {
    let whole=NSBezierPath(ovalIn:NSRect(x:c.x-r,y:c.y-r,width:r*2,height:r*2));whole.lineWidth=3;track.setStroke();whole.stroke()
    guard progress>0 else{return}
    let arc=progress>=1 ? whole:NSBezierPath()
    if progress<1{arc.appendArc(withCenter:c,radius:r,startAngle:90,endAngle:90-360*progress,clockwise:true)}
    arc.lineWidth=3;arc.lineCapStyle = .round;color.setStroke();arc.stroke()
}

// One step of connecting: the closed case before Connect, the lid opening, the
// lid opening once and staying open, the lid closing, the quarter turn
// clockwise, or the case upright and pointing. Moving steps loop while visible;
// with Reduce Motion they hold a still, and the turn keeps its arrow.
final class CaseStepView:NSView {
    var step=CaseStep.open {
        didSet {
            guard step != oldValue else{return}
            started=CACurrentMediaTime();needsDisplay=true;updateMotion()
            setAccessibilityLabel(Self.labels[step])
        }
    }
    var fill:CGFloat=0.86{didSet{needsDisplay=true}}
    // A ring around the case while it's being held still; nil hides it.
    var holdProgress:CGFloat?{didSet{if holdProgress != oldValue{needsDisplay=true;setAccessibilityValue(holdProgress.map{"\(Int($0*100)) percent"})}}}
    // Checks and previews pin the loop to one moment.
    var pinnedTime:Double?{didSet{needsDisplay=true;updateMotion()}}
    private var timer:Timer?
    private var started=CACurrentMediaTime()
    private static let openOnce=1.3
    private var occlusion:NSObjectProtocol?
    private static let labels:[CaseStep:String]=[
        .closed:"AirPods case with the lid closed",
        .opening:"The lid opening over both AirPods",
        .open:"AirPods case with the lid open and both AirPods inside",
        .close:"The lid closing over both AirPods",
        .turn:"The closed case turning a quarter turn clockwise to stand upright",
        .point:"The closed case held upright",
    ]
    init() {
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false
        setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel(Self.labels[step])
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    deinit{timer?.invalidate();if let occlusion{NotificationCenter.default.removeObserver(occlusion)}}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A closed or covered window stops the loops, so the menu-bar app idles.
        if let occlusion{NotificationCenter.default.removeObserver(occlusion)};occlusion=nil
        if let window{occlusion=NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main){[weak self] _ in self?.updateMotion()}}
        updateMotion()
    }
    override func viewDidHide(){super.viewDidHide();updateMotion()}
    override func viewDidUnhide(){super.viewDidUnhide();updateMotion()}
    private var still:Bool{NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    private func updateMotion() {
        let visible=window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !still
        // The open step plays once, so its timer stops when the lid is up.
        let opened=step == .open && CACurrentMediaTime()-started>Self.openOnce
        let moving=(step == .opening || step == .close || step == .turn || step == .open && !opened) && visible
        if moving && timer==nil {
            let next=Timer(timeInterval:1.0/30,repeats:true){[weak self] _ in guard let self else{return};needsDisplay=true;if step == .open{updateMotion()}}
            RunLoop.main.add(next,forMode:.common);timer=next
        }else if !moving{timer?.invalidate();timer=nil}
    }
    // Every frame spans about 0.72 of its square canvas, so this keeps the
    // case the same size in every step and clear of the edges mid-turn.
    private func artRect()->NSRect {
        let side=min(bounds.width,bounds.height)*fill/0.72
        return NSRect(x:bounds.midX-side/2,y:bounds.midY-side/2,width:side,height:side)
    }
    override func draw(_ dirtyRect:NSRect) {
        drawArt(dirtyRect)
        if let holdProgress {
            rkDrawRing(center:NSPoint(x:bounds.midX,y:bounds.midY),radius:min(bounds.width,bounds.height)*0.46,progress:holdProgress,track:NSColor.white.withAlphaComponent(0.18),arc:.systemGreen)
        }
    }
    private func drawArt(_ dirtyRect:NSRect) {
        guard let art=CaseStepArt.shared else {
            let outline=NSBezierPath(roundedRect:bounds.insetBy(dx:bounds.width*0.3,dy:bounds.height*0.18),xRadius:20,yRadius:20)
            HomePalette.track.setStroke();outline.lineWidth=2;outline.stroke();return
        }
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect=artRect(),t=pinnedTime ?? CACurrentMediaTime()-started,closed=art.lid[11]
        func ease(_ x:Double)->Double{let u=min(1,max(0,x));return u*u*(3-2*u)}
        switch step {
        case .open:
            // Looking for the AirPods: hold closed, open over 0.9 s, then stay open.
            if still || t>=Self.openOnce{draw(art.lid[0],in:rect);return}
            if t<0.4{draw(closed,in:rect)}else{draw(art.lid[max(0,11-Int((t-0.4)/0.9*12))],in:rect)}
        case .point:draw(art.front,in:rect)
        case .closed:draw(closed,in:rect)
        case .opening:
            // The close in reverse: hold closed, open over 0.9 s, hold open, fade back.
            if still{draw(art.lid[0],in:rect);return}
            let u=t.truncatingRemainder(dividingBy:3.4)
            if u<0.7{draw(closed,in:rect)}
            else if u<1.6{draw(art.lid[max(0,11-Int((u-0.7)/0.9*12))],in:rect)}
            else if u<3.0{draw(art.lid[0],in:rect)}
            else{let k=CGFloat(ease((u-3.0)/0.4));draw(art.lid[0],in:rect,alpha:1-k);draw(closed,in:rect,alpha:k)}
        case .close:
            // Hold open, close over 0.9 s (the frames are already eased), hold closed, fade back.
            if still{draw(closed,in:rect);return}
            let u=t.truncatingRemainder(dividingBy:3.4)
            if u<0.7{draw(art.lid[0],in:rect)}
            else if u<1.6{draw(art.lid[min(11,Int((u-0.7)/0.9*12))],in:rect)}
            else if u<3.0{draw(closed,in:rect)}
            else{let k=CGFloat(ease((u-3.0)/0.4));draw(closed,in:rect,alpha:1-k);draw(art.lid[0],in:rect,alpha:k)}
        case .turn:
            // A quarter turn clockwise about the shared image center, landing on the upright render.
            if still{draw(closed,in:rect);drawTurnArrow(rect,alpha:1);return}
            let u=t.truncatingRemainder(dividingBy:3.6)
            if u<0.7{draw(closed,in:rect);drawTurnArrow(rect,alpha:1)}
            else if u<1.7 {
                let k=ease(u-0.7),angle=CGFloat(90*k),swap=CGFloat(ease((k-0.75)/0.25))
                draw(closed,in:rect,alpha:1-swap,rotation:-angle);draw(art.front,in:rect,alpha:swap,rotation:90-angle)
                drawTurnArrow(rect,alpha:1-CGFloat(k))
            }
            else if u<3.1{draw(art.front,in:rect)}
            else{let k=CGFloat(ease((u-3.1)/0.5));draw(art.front,in:rect,alpha:1-k);draw(closed,in:rect,alpha:k);drawTurnArrow(rect,alpha:k)}
        }
    }
    private func draw(_ image:NSImage,in rect:NSRect,alpha:CGFloat=1,rotation:CGFloat=0) {
        guard alpha>0.001 else{return}
        NSGraphicsContext.saveGraphicsState()
        if rotation != 0 {
            let transform=NSAffineTransform()
            transform.translateX(by:rect.midX,yBy:rect.midY);transform.rotate(byDegrees:rotation);transform.translateX(by:-rect.midX,yBy:-rect.midY)
            transform.concat()
        }
        let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.14*alpha)
        shadow.shadowBlurRadius=max(6,rect.width*0.04);shadow.shadowOffset=NSSize(width:0,height:-rect.width*0.02);shadow.set()
        image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:alpha,respectFlipped:true,hints:nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    // A clockwise arc to the right of the case, in white on the dark stage.
    private func drawTurnArrow(_ rect:NSRect,alpha:CGFloat) {
        guard alpha>0.001 else{return}
        let center=NSPoint(x:rect.midX,y:rect.midY),radius=rect.width*0.47,line=max(2,rect.width*0.012)
        let end:CGFloat = -28,arc=NSBezierPath()
        arc.appendArc(withCenter:center,radius:radius,startAngle:34,endAngle:end,clockwise:true)
        arc.lineWidth=line;arc.lineCapStyle = .round
        NSColor(white:1,alpha:0.55*alpha).setStroke();arc.stroke()
        let radians=end * .pi/180,tip=NSPoint(x:center.x+radius*cos(radians),y:center.y+radius*sin(radians))
        let along=NSPoint(x:sin(radians),y:-cos(radians)),across=NSPoint(x:cos(radians),y:sin(radians)),size=line*3.2
        let head=NSBezierPath()
        head.move(to:NSPoint(x:tip.x-along.x*size+across.x*size*0.8,y:tip.y-along.y*size+across.y*size*0.8))
        head.line(to:tip)
        head.line(to:NSPoint(x:tip.x-along.x*size-across.x*size*0.8,y:tip.y-along.y*size-across.y*size*0.8))
        head.lineWidth=line;head.lineCapStyle = .round;head.lineJoinStyle = .round;head.stroke()
    }
}

// MARK: - Live pointer

// A miniature dark display with the laser dot where the pointer is. The
// point is normalized with the origin at the top-left, like screen points.
final class AimPadView:NSView {
    var point=CGPoint(x:0.5,y:0.5){didSet{record()}}
    var live=false{didSet{if live != oldValue{trail.removeAll();needsDisplay=true}}}
    var caption=""{didSet{if caption != oldValue{needsDisplay=true}}}
    var cornerRadius:CGFloat=12{didSet{needsDisplay=true}}
    private var trail:[(point:CGPoint,time:CFTimeInterval)]=[]
    override var isFlipped:Bool{true}
    init(){super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false;setAccessibilityElement(false)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    private func record() {
        let now=CACurrentMediaTime()
        if live{trail.append((point,now));trail.removeAll{now-$0.time>0.3};if trail.count>20{trail.removeFirst(trail.count-20)}}
        needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        let frame=bounds.insetBy(dx:0.5,dy:0.5)
        HomePalette.screen.setFill();NSBezierPath(roundedRect:frame,xRadius:cornerRadius,yRadius:cornerRadius).fill()
        let inner=frame.insetBy(dx:14,dy:14)
        let grid=NSBezierPath()
        for i in 1..<3 {
            let x=inner.minX+inner.width*CGFloat(i)/3,y=inner.minY+inner.height*CGFloat(i)/3
            grid.move(to:NSPoint(x:x,y:inner.minY));grid.line(to:NSPoint(x:x,y:inner.maxY))
            grid.move(to:NSPoint(x:inner.minX,y:y));grid.line(to:NSPoint(x:inner.maxX,y:y))
        }
        NSColor(white:1,alpha:0.06).setStroke();grid.lineWidth=1;grid.stroke()
        let cross=NSBezierPath()
        cross.move(to:NSPoint(x:inner.midX-6,y:inner.midY));cross.line(to:NSPoint(x:inner.midX+6,y:inner.midY))
        cross.move(to:NSPoint(x:inner.midX,y:inner.midY-6));cross.line(to:NSPoint(x:inner.midX,y:inner.midY+6))
        NSColor(white:1,alpha:0.2).setStroke();cross.stroke()
        func place(_ p:CGPoint)->NSPoint{NSPoint(x:inner.minX+min(1,max(0,p.x))*inner.width,y:inner.minY+min(1,max(0,p.y))*inner.height)}
        let dot=place(point)
        if live {
            if trail.count>1 {
                let now=CACurrentMediaTime()
                for (a,b) in zip(trail,trail.dropFirst()) {
                    let path=NSBezierPath();path.move(to:place(a.point));path.line(to:place(b.point))
                    path.lineWidth=2;path.lineCapStyle = .round
                    HomePalette.laser.withAlphaComponent(CGFloat(max(0,0.45*(1-(now-b.time)/0.3)))).setStroke();path.stroke()
                }
            }
            HomePalette.laser.withAlphaComponent(0.16).setFill();NSBezierPath(ovalIn:NSRect(x:dot.x-13,y:dot.y-13,width:26,height:26)).fill()
            HomePalette.laser.withAlphaComponent(0.32).setFill();NSBezierPath(ovalIn:NSRect(x:dot.x-9,y:dot.y-9,width:18,height:18)).fill()
            HomePalette.laser.setFill();NSBezierPath(ovalIn:NSRect(x:dot.x-6,y:dot.y-6,width:12,height:12)).fill()
        } else {
            let ring=NSBezierPath(ovalIn:NSRect(x:dot.x-6,y:dot.y-6,width:12,height:12));ring.lineWidth=1.5
            NSColor(white:1,alpha:0.5).setStroke();ring.stroke()
        }
        if !caption.isEmpty {
            (caption as NSString).draw(at:NSPoint(x:frame.minX+12,y:frame.maxY-22),withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor(white:1,alpha:0.55)])
        }
    }
}
