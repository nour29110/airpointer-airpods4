import AppKit
import QuartzCore

// Full-screen grip calibration. Each target captures itself once the case has
// been still for a moment, so the hand that isn't holding the case stays free.
final class CaseCalibrator:NSObject {
    var onCancel:(()->Void)?
    // The closed case keeps its own grip math: the three captured poses go here.
    // Cleared when the overlay closes.
    var closedCase:((Pose,Pose,Pose) throws->Void)?
    // Set when the closed case kept its edges: only the center is captured. It returns false
    // when the case is held another way, and calibration goes on to the two edges.
    var closedCenter:((Pose) throws->Bool)?
    var isActive:Bool{phase != .idle}
    private enum Phase{case idle,aiming,done}
    private var phase=Phase.idle
    private let overlay=CalibrationOverlayView(frame:NSRect(x:0,y:0,width:1440,height:900))
    private var window:CalibrationWindow?
    private var display:NSScreen?
    private var link:CADisplayLink?
    private var step=0,steps=3
    private var poses:[Pose]=[]
    private var recent:[MotionFrame]=[]
    private var collected:[MotionFrame]=[]
    private var collectStart:CFTimeInterval?
    private var lastReceived:CFTimeInterval=0
    private var lastUpdate:CFTimeInterval=0
    private var generation=0
    private let degree=Double.pi/180

    override init() {
        super.init()
        overlay.onCapture={[weak self] in self?.captureNow()}
        overlay.onCancel={[weak self] in self?.cancel()}
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
    }
    func show(on screen:NSScreen?) {
        guard let screen=screen ?? NSScreen.main else{return}
        generation+=1;display=screen
        step=0;steps=closedCenter != nil ? 1:3;poses=[];recent=[];collected=[];collectStart=nil
        overlay.step=0;overlay.steps=steps;overlay.progress=0;overlay.hint = .none;overlay.message=nil;overlay.waiting=false;overlay.success=false
        // Counts as fresh, so "Waiting for your AirPods" doesn't flash before the first frame.
        lastReceived=CACurrentMediaTime();lastUpdate=lastReceived;phase = .aiming
        let window=self.window ?? makeWindow()
        window.setFrame(screen.frame,display:false)
        window.alphaValue=0;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(overlay)
        NSApp.activate()
        NSAnimationContext.runAnimationGroup{$0.duration=0.2;window.animator().alphaValue=1}
        if link == nil{let link=overlay.displayLink(target:self,selector:#selector(refresh(_:)));link.add(to:.main,forMode:.common);self.link=link}
        NSCursor.setHiddenUntilMouseMoves(true)
        announce(steps==1 ? "Recenter. Point at the dot and keep still.":"Calibration, step 1 of 3. Point at the dot and keep still.")
    }
    func feed(_ frame:MotionFrame) {
        guard phase == .aiming else{return}
        let now=CACurrentMediaTime();lastReceived=now
        // A gap or a different earbud breaks stillness, so the window starts over.
        if let last=recent.last,frame.t<last.t || frame.t-last.t>=0.16 {
            recent=[];if collectStart != nil{drop()}
        }
        recent.append(frame)
        while let first=recent.first,frame.t-first.t>0.4{recent.removeFirst()}
        if let start=collectStart {
            collected.append(frame)
            if spread(collected)>=3*degree{drop(steadier:true)}else if now-start>=0.8{finish()}
            return
        }
        // Holding still on an earlier target would capture the same pose twice.
        if poses.contains(where:{frame.pose.rotation(from:$0).length<5*degree}){overlay.hint = .move;return}
        if overlay.hint == .move{overlay.hint = .none}
        if let first=recent.first,frame.t-first.t>=0.35,spread(recent)<1.5*degree{begin(frame)}
    }
    func disconnected() {
        guard phase == .aiming else{return}
        if step>0 || collectStart != nil{restart("Motion was interrupted. Start again from the center.")}else{recent=[]}
    }
    func cancel() {
        guard phase != .idle else{return}
        let completed=phase == .done
        close()
        if !completed{onCancel?()}
    }

    private func begin(_ frame:MotionFrame){collected=[frame];collectStart=CACurrentMediaTime()}
    private func captureNow() {
        guard phase == .aiming,collectStart == nil,!overlay.waiting,let frame=recent.last else{return}
        if poses.contains(where:{frame.pose.rotation(from:$0).length<5*degree}){overlay.hint = .move;return}
        begin(frame)
    }
    private func drop(steadier:Bool=false,message:String?=nil) {
        collectStart=nil;collected=[]
        if steadier && overlay.hint != .steadier{overlay.hint = .steadier;announce("Hold a little steadier.")}
        if let message{overlay.message=message}
    }
    private func spread(_ frames:[MotionFrame])->Double {
        guard let mean=Pose.mean(frames.map(\.pose)) else{return .infinity}
        return frames.reduce(0){max($0,$1.pose.rotation(from:mean).length)}
    }
    private func finish() {
        let captured=collected;collectStart=nil;collected=[]
        guard captured.count>=12,
              let mean=Pose.mean(captured.map(\.pose)),let first=captured.first,let last=captured.last,
              last.t-first.t>0.4,
              zip(captured,captured.dropFirst()).allSatisfy({$1.t-$0.t<0.16}) else {
            drop(message:"Motion dropped during the capture. Keep still to try again.");return
        }
        let spread=captured.map{$0.pose.rotation(from:mean).length}.max() ?? 99
        guard spread<3*Double.pi/180 else{drop(steadier:true);return}
        poses.append(mean);recent=[]
        overlay.hint = .none;overlay.message=nil
        if steps==1,let closedCenter {
            do{if try closedCenter(poses[0]){complete();return}}catch{restart(error.localizedDescription);return}
            steps=3;overlay.steps=3;step=1;overlay.step=1;overlay.progress=0
            overlay.message="You’re holding the case differently from last time, so aim at the edges too."
            announce("Center captured. The grip changed, so step 2 of 3: now the right edge.")
            return
        }
        guard step==2 else {
            step+=1;overlay.step=step;overlay.progress=0
            announce(step==1 ? "Center captured. Step 2 of 3: now the right edge.":"Right edge captured. Step 3 of 3: now the top edge.")
            return
        }
        do {try closedCase?(poses[0],poses[1],poses[2]);complete()}catch{restart(error.localizedDescription)}
    }
    private func complete() {
        phase = .done;overlay.success=true;overlay.progress=1;overlay.pulse=0
        announce("Calibrated. Point back at the center — you’re ready.")
        let token=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2){[weak self] in
            guard let self,self.generation==token,self.phase == .done else{return}
            self.close()
        }
    }
    private func restart(_ reason:String) {
        step=0;poses=[];recent=[];collected=[];collectStart=nil
        overlay.step=0;overlay.progress=0;overlay.hint = .none;overlay.message=reason
        announce("\(reason) Point at the dot.")
    }
    @objc private func refresh(_ link:CADisplayLink){update()}
    private func update() {
        let now=CACurrentMediaTime(),elapsed=min(0.1,max(0,now-lastUpdate));lastUpdate=now
        guard phase == .aiming else{return}
        let waiting=now-lastReceived>0.4
        if waiting != overlay.waiting {
            overlay.waiting=waiting
            if waiting{recent=[];collected=[];collectStart=nil;announce("Waiting for your AirPods.")}
        }
        if !waiting {
            if let start=collectStart{overlay.progress=CGFloat(min(1,(now-start)/0.8))}
            else if overlay.progress>0{overlay.progress=max(0,overlay.progress-CGFloat(elapsed/0.3))}
        }
        overlay.pulse=waiting || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:CGFloat(0.5-0.5*cos(now*2*Double.pi/1.8))
    }
    private func close() {
        phase = .idle;generation+=1;closedCase=nil;closedCenter=nil
        link?.invalidate();link=nil
        recent=[];collected=[];collectStart=nil
        guard let window,window.isVisible else{return}
        let token=generation
        NSAnimationContext.runAnimationGroup({$0.duration=0.15;window.animator().alphaValue=0}){[weak self] in
            if self?.generation ?? token == token{window.orderOut(nil)}
        }
    }
    private func makeWindow()->CalibrationWindow {
        let window=CalibrationWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.isOpaque=true;window.hasShadow=false;window.backgroundColor = .black
        window.level=NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1)
        window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        window.animationBehavior = .none;window.title="Calibrate AirPointer"
        window.contentView=overlay
        self.window=window
        return window
    }
    @objc private func screensChanged() {
        guard phase != .idle,let window else{return}
        let key=NSDeviceDescriptionKey("NSScreenNumber"),id=display?.deviceDescription[key] as? NSNumber
        guard let screen=NSScreen.screens.first(where:{$0.deviceDescription[key] as? NSNumber==id}) ?? NSScreen.main else{return}
        display=screen;window.setFrame(screen.frame,display:true)
    }
    private func announce(_ text:String) {
        NSAccessibility.post(element:window ?? overlay,notification:.announcementRequested,
                             userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])
    }
}

private final class CalibrationWindow:NSWindow {
    override var canBecomeKey:Bool{true}
    override var canBecomeMain:Bool{true}
    // Covers the menu bar too, so AppKit mustn't nudge the frame below it.
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?)->NSRect{frameRect}
}

// Draws calibration and nothing else. Every visible state is a plain
// property, so previews can render any moment without motion.
final class CalibrationOverlayView:NSView {
    enum Hint{case none,move,steadier}
    static let stepNames=["Center","Right edge","Top edge"]
    static let ringRadius:CGFloat=44
    var step=0{didSet{if step != oldValue{refreshState()}}}
    // 1 when saved edges leave only the center.
    var steps=3{didSet{if steps != oldValue{refreshState()}}}
    var progress:CGFloat=0{didSet{target.progress=min(1,max(0,progress))}}
    var hint=Hint.none{didSet{if hint != oldValue{refreshState()}}}
    var message:String?{didSet{if message != oldValue{refreshState()}}}
    var waiting=false{didSet{if waiting != oldValue{refreshState()}}}
    var success=false{didSet{if success != oldValue{refreshState()}}}
    var pulse:CGFloat=0{didSet{target.pulse=pulse}}
    var onCapture:(()->Void)?
    var onCancel:(()->Void)?
    private let target=CalibrationTarget()
    private let hintChip=CalibrationHint()
    private let heading=rkTitle("",32,align:.center)
    private let detail=rkWrap("",15,align:.center)
    private lazy var detailWidth=detail.widthAnchor.constraint(equalToConstant:600)
    private let stepRow=CalibrationSteps()
    private let brand=rkLabel("",13,.medium,.tertiaryLabelColor)
    private let footer:NSStackView = {
        let capture=rkLabel("Capture now",13,.regular,.tertiaryLabelColor),cancel=rkLabel("Cancel",13,.regular,.tertiaryLabelColor)
        capture.setAccessibilityLabel("Press Space to capture now");cancel.setAccessibilityLabel("Press Escape to cancel")
        let stack=rkHStack([KeyCap("Space"),capture,KeyCap("Esc"),cancel],spacing:8);stack.setCustomSpacing(24,after:capture)
        return stack
    }()
    private lazy var cancelButton=RemoteButton("Cancel",style:.tertiary,height:28,target:self,action:#selector(cancelClicked))

    // The center, about 80 pt in from the right edge, or 80 pt down from the top.
    static func targetPoint(for step:Int,in bounds:NSRect)->NSPoint {
        switch step {
        case 1:return NSPoint(x:bounds.maxX-80,y:bounds.midY)
        case 2:return NSPoint(x:bounds.midX,y:bounds.maxY-80)
        default:return NSPoint(x:bounds.midX,y:bounds.midY)
        }
    }
    override init(frame:NSRect) {
        super.init(frame:frame)
        appearance=NSAppearance(named:.darkAqua)
        setAccessibilityRole(.group);setAccessibilityLabel("Calibration")
        let title=rkHStack([rkSymbolView("airpodspro.chargingcase.wireless",13),brand],spacing:8)
        let text=rkVStack([heading,detail,stepRow],spacing:8,align:.centerX);text.setCustomSpacing(24,after:detail)
        cancelButton.refusesFirstResponder=true
        for view in [title,cancelButton,text,footer,target,hintChip] as [NSView]{addSubview(view)}
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo:leadingAnchor,constant:32),
            title.centerYAnchor.constraint(equalTo:topAnchor,constant:36),
            cancelButton.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-22),
            cancelButton.centerYAnchor.constraint(equalTo:title.centerYAnchor),
            footer.centerXAnchor.constraint(equalTo:centerXAnchor),
            footer.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-32),
            text.centerXAnchor.constraint(equalTo:centerXAnchor),
            text.bottomAnchor.constraint(equalTo:footer.topAnchor,constant:-48),
            text.leadingAnchor.constraint(greaterThanOrEqualTo:leadingAnchor,constant:32),
            heading.widthAnchor.constraint(equalTo:text.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo:text.widthAnchor),
        ])
        // Centered text in fixed columns, narrowed only on small screens.
        let column=text.widthAnchor.constraint(equalToConstant:760);column.priority = .defaultHigh;column.isActive=true
        detailWidth.priority = .defaultHigh;detailWidth.isActive=true
        refreshState()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}

    private func refreshState() {
        let current=min(max(step,0),2)
        // A restart reason reads a step louder than the quiet line it replaces.
        let notice=message != nil && !success && !waiting
        if success {
            rkSetText(heading,"Calibrated");rkSetText(detail,steps==1 ? "You’re ready.":"Point back at the center — you’re ready.")
        } else if waiting {
            rkSetText(heading,"Waiting for your AirPods")
            rkSetText(detail,"Keep the closed case upright and still. If nothing moves, connect again, then open the lid.")
        } else {
            rkSetText(heading,["Point at the dot","Now the right edge","Now the top edge"][current])
            rkSetText(detail,message ?? (steps==1 ? "Your edges are saved, so this is the only dot. Keep still for a moment.":"Hold the case the way you’ll point with it. Keep still for a moment."))
        }
        detail.textColor=notice ? .labelColor:.secondaryLabelColor
        detail.font = .systemFont(ofSize:15,weight:notice ? .medium:.regular)
        // Even line lengths, so a two-line reason never leaves one word behind.
        let single=ceil((detail.stringValue as NSString).size(withAttributes:[.font:detail.font!]).width)
        let lines=max(1,ceil(single/600))
        detailWidth.constant=lines<2 ? 600:min(600,ceil(single/lines)+48)
        rkSetText(brand,success ? "AirPointer · Calibrated":steps==1 ? "AirPointer · Recentering":"AirPointer · Calibrating")
        stepRow.current=success ? 3:current;stepRow.isHidden=steps==1
        target.isHidden=success;target.live = !waiting
        target.setAccessibilityLabel("\(Self.stepNames[current]) target")
        switch hint {
        case .none:hintChip.set("",symbol:nil)
        case .steadier:hintChip.set("Hold a little steadier",symbol:"hand.raised")
        case .move:hintChip.set(current==2 ? "Move toward the top edge":"Move toward the right edge",symbol:current==2 ? "arrow.up":"arrow.right")
        }
        hintChip.isHidden=hint == .none || waiting || success
        footer.isHidden=success;cancelButton.isHidden=success
        needsLayout=true;needsDisplay=true
    }
    override func layout() {
        super.layout()
        let p=Self.targetPoint(for:min(max(step,0),2),in:bounds),side=target.frame.width
        target.frame=NSRect(x:round(p.x-side/2),y:round(p.y-side/2),width:side,height:side)
        let size=hintChip.intrinsicContentSize
        let x=min(max(24,p.x-size.width/2),bounds.maxX-24-size.width)
        hintChip.frame=NSRect(x:round(x),y:round(p.y-Self.ringRadius-24-size.height),width:size.width,height:size.height)
    }
    override func draw(_ dirtyRect:NSRect) {
        HomePalette.screen.setFill();dirtyRect.fill()
        // A faint pool of light in the middle, like a projector on a dark wall.
        if let glow=NSGradient(colors:[NSColor(white:1,alpha:0.035),NSColor(white:1,alpha:0)]) {
            NSGraphicsContext.saveGraphicsState()
            let transform=NSAffineTransform();transform.translateX(by:bounds.midX,yBy:bounds.midY)
            transform.scaleX(by:bounds.width/max(1,bounds.height),yBy:1);transform.concat()
            glow.draw(fromCenter:.zero,radius:0,toCenter:.zero,radius:bounds.height*0.5,options:[])
            NSGraphicsContext.restoreGraphicsState()
        }
        for index in success ? (steps==1 ? []:[1,2]):Array(0..<min(max(step,0),3)) {
            let p=Self.targetPoint(for:index,in:bounds)
            let ring=NSBezierPath(ovalIn:NSRect(x:p.x-24,y:p.y-24,width:48,height:48));ring.lineWidth=1.5
            NSColor.tertiaryLabelColor.setStroke();ring.stroke()
            let check=calibrationCheck(at:p,side:20);check.lineWidth=2;NSColor.secondaryLabelColor.setStroke();check.stroke()
        }
        if success {
            let p=Self.targetPoint(for:0,in:bounds)
            HomePalette.ink.setFill();NSBezierPath(ovalIn:NSRect(x:p.x-36,y:p.y-36,width:72,height:72)).fill()
            let check=calibrationCheck(at:p,side:36);check.lineWidth=4;HomePalette.screen.setStroke();check.stroke()
        }
    }
    override var acceptsFirstResponder:Bool{true}
    override func keyDown(with event:NSEvent) {
        switch event.keyCode {
        case 49:if !event.isARepeat{onCapture?()}
        case 53:onCancel?()
        default:super.keyDown(with:event)
        }
    }
    override func cancelOperation(_ sender:Any?){onCancel?()}
    @objc private func cancelClicked(){onCancel?()}
}

// The check from the mocks, drawn in a square of the given side centered on p.
private func calibrationCheck(at p:NSPoint,side:CGFloat)->NSBezierPath {
    let s=side/20,x=p.x-side/2,y=p.y-side/2
    let path=NSBezierPath();path.lineCapStyle = .round;path.lineJoinStyle = .round
    path.move(to:NSPoint(x:x+5*s,y:y+9.6*s));path.line(to:NSPoint(x:x+8.2*s,y:y+6.4*s));path.line(to:NSPoint(x:x+15.2*s,y:y+13.6*s))
    return path
}

// The live target: a laser dot inside the ring that fills while the case holds still.
private final class CalibrationTarget:NSView {
    var progress:CGFloat=0{didSet{if progress != oldValue{needsDisplay=true}}}
    var pulse:CGFloat=0{didSet{if pulse != oldValue && live{needsDisplay=true}}}
    var live=true{didSet{if live != oldValue{needsDisplay=true}}}
    init(){super.init(frame:NSRect(x:0,y:0,width:128,height:128))}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func isAccessibilityElement()->Bool{true}
    override func accessibilityRole()->NSAccessibility.Role?{.progressIndicator}
    override func accessibilityValue()->Any?{NSNumber(value:Double(progress))}
    override func accessibilityMinValue()->Any?{NSNumber(value:0)}
    override func accessibilityMaxValue()->Any?{NSNumber(value:1)}
    override func draw(_ dirtyRect:NSRect) {
        let c=NSPoint(x:bounds.midX,y:bounds.midY),r=CalibrationOverlayView.ringRadius
        func disc(_ radius:CGFloat)->NSBezierPath{NSBezierPath(ovalIn:NSRect(x:c.x-radius,y:c.y-radius,width:radius*2,height:radius*2))}
        rkDrawRing(center:c,radius:r,progress:progress,track:HomePalette.track,arc:live ? HomePalette.laser:NSColor.secondaryLabelColor)
        if live {
            HomePalette.laser.withAlphaComponent(0.16*(1-0.5*pulse)).setFill();disc(13+5*pulse).fill()
            HomePalette.laser.withAlphaComponent(0.32).setFill();disc(9.5).fill()
            HomePalette.laser.setFill();disc(7).fill()
        } else {
            let ring=disc(6.5);ring.lineWidth=1.5;NSColor.secondaryLabelColor.setStroke();ring.stroke()
        }
    }
}

// A quiet capsule under the target: "Hold a little steadier", "Move toward…".
private final class CalibrationHint:NSView {
    private var text=""
    private var symbol:String?
    private let font=NSFont.systemFont(ofSize:13,weight:.medium)
    init(){super.init(frame:.zero)}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func set(_ text:String,symbol:String?) {
        guard text != self.text || symbol != self.symbol else{return}
        self.text=text;self.symbol=symbol
        setAccessibilityLabel(text);needsDisplay=true;invalidateIntrinsicContentSize()
    }
    private var image:NSImage?{symbol.flatMap{rkSymbol($0,12,.semibold)}}
    override func isAccessibilityElement()->Bool{!text.isEmpty}
    override func accessibilityRole()->NSAccessibility.Role?{.staticText}
    override var intrinsicContentSize:NSSize {
        let icon=image.map{ceil($0.size.width)+8} ?? 0
        return NSSize(width:ceil((text as NSString).size(withAttributes:[.font:font]).width)+icon+32,height:32)
    }
    override func draw(_ dirtyRect:NSRect) {
        HomePalette.control.setFill();NSBezierPath(roundedRect:bounds,xRadius:bounds.height/2,yRadius:bounds.height/2).fill()
        var x:CGFloat=16
        if let image {
            let rect=NSRect(x:x,y:floor((bounds.height-image.size.height)/2),width:image.size.width,height:image.size.height)
            NSImage(size:image.size,flipped:false){frame in image.draw(in:frame);NSColor.labelColor.set();frame.fill(using:.sourceAtop);return true}.draw(in:rect)
            x+=ceil(image.size.width)+8
        }
        let size=(text as NSString).size(withAttributes:[.font:font])
        (text as NSString).draw(at:NSPoint(x:x,y:floor((bounds.height-size.height)/2)),withAttributes:[.font:font,.foregroundColor:NSColor.labelColor])
    }
}

// 1 Center · 2 Right edge · 3 Top edge, with done, current and next states.
private final class CalibrationSteps:NSView {
    var current=0{didSet{if current != oldValue{needsDisplay=true;describe()}}}
    private let names=CalibrationOverlayView.stepNames
    private let font=NSFont.systemFont(ofSize:13),strong=NSFont.systemFont(ofSize:13,weight:.semibold)
    private let number=NSFont.systemFont(ofSize:11,weight:.bold)
    init(){super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false;describe()}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func isAccessibilityElement()->Bool{true}
    override func accessibilityRole()->NSAccessibility.Role?{.staticText}
    private func describe(){setAccessibilityLabel(current<names.count ? "Step \(current+1) of \(names.count): \(names[current])":"All \(names.count) steps done")}
    // Widths use the semibold face, so the row doesn't shift as the current step moves.
    private func width(_ name:String)->CGFloat{ceil((name as NSString).size(withAttributes:[.font:strong]).width)}
    override var intrinsicContentSize:NSSize {
        NSSize(width:names.reduce(0){$0+28+width($1)}+CGFloat(names.count-1)*52,height:20)
    }
    override func draw(_ dirtyRect:NSRect) {
        var x:CGFloat=0
        for (index,name) in names.enumerated() {
            if index>0 {
                HomePalette.rule.setFill();NSRect(x:x+12,y:floor(bounds.midY),width:28,height:1).fill()
                x+=52
            }
            let badge=NSRect(x:x,y:floor((bounds.height-20)/2),width:20,height:20)
            var label=NSColor.secondaryLabelColor,face=font
            if index<current {
                HomePalette.control.setFill();NSBezierPath(ovalIn:badge).fill()
                let check=calibrationCheck(at:NSPoint(x:badge.midX,y:badge.midY),side:16);check.lineWidth=1.6
                NSColor.labelColor.setStroke();check.stroke()
            } else {
                let digit="\(index+1)" as NSString,size=digit.size(withAttributes:[.font:number])
                var ink=NSColor.secondaryLabelColor
                if index==current {
                    HomePalette.ink.setFill();NSBezierPath(ovalIn:badge).fill()
                    ink=HomePalette.screen;label = .labelColor;face=strong
                } else {
                    let ring=NSBezierPath(ovalIn:badge.insetBy(dx:0.75,dy:0.75));ring.lineWidth=1.5
                    NSColor.tertiaryLabelColor.setStroke();ring.stroke()
                }
                digit.draw(at:NSPoint(x:badge.midX-size.width/2,y:badge.midY-size.height/2),withAttributes:[.font:number,.foregroundColor:ink])
            }
            let size=(name as NSString).size(withAttributes:[.font:face])
            (name as NSString).draw(at:NSPoint(x:x+28,y:floor((bounds.height-size.height)/2)),withAttributes:[.font:face,.foregroundColor:label])
            x+=28+width(name)
        }
    }
}
