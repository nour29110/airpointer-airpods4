import AppKit
import Carbon

// The one shortcut that works from any app: it connects, cancels, and turns pointing on and off. Either modifier keys alone,
// which have to include fn (fn ⌃), or a key with ⌃ or ⌥ (⌃⌥P). Anything looser would go off during typing or other apps' shortcuts.
struct PointerShortcut:Equatable {
    static let relevant:NSEvent.ModifierFlags=[.function,.control,.option,.shift,.command]
    static let fnControl=PointerShortcut(modifiers:[.function,.control])
    private static let storageKey="pointerShortcut"
    private(set) static var current=load(from:.standard)
    enum Recorded:Equatable{case shortcut(PointerShortcut),refused(String)}

    var modifiers:NSEvent.ModifierFlags,key:UInt16?=nil,keyName:String?=nil

    var label:String{([modifiers.contains(.function) ? "fn":nil,glyphs+(keyName ?? "")].compactMap{$0}).filter{!$0.isEmpty}.joined(separator:" ")}
    var spoken:String {
        let names=[(NSEvent.ModifierFlags.function,"fn"),(.control,"Control"),(.option,"Option"),(.shift,"Shift"),(.command,"Command")]
        return (names.filter{modifiers.contains($0.0)}.map(\.1)+(keyName.map{[$0]} ?? [])).joined(separator:" ")
    }
    private var glyphs:String {
        [(NSEvent.ModifierFlags.control,"⌃"),(.option,"⌥"),(.shift,"⇧"),(.command,"⌘")].filter{modifiers.contains($0.0)}.map(\.1).joined()
    }
    var carbonModifiers:UInt32 {
        var value=0
        if modifiers.contains(.control){value|=controlKey}
        if modifiers.contains(.option){value|=optionKey}
        if modifiers.contains(.shift){value|=shiftKey}
        if modifiers.contains(.command){value|=cmdKey}
        return UInt32(value)
    }

    // `special` is an arrow or function key: macOS reports those with the fn flag even when fn isn't down.
    static func recorded(_ flags:NSEvent.ModifierFlags,key:UInt16?=nil,name:String?=nil,special:Bool=false)->Recorded {
        var modifiers=flags.intersection(relevant)
        guard let key else{
            guard modifiers.contains(.function),modifiers != .function else{return .refused("Use fn with another modifier key, or a key with ⌃ or ⌥.")}
            return .shortcut(PointerShortcut(modifiers:modifiers))
        }
        if special{modifiers.remove(.function)}
        guard !modifiers.contains(.function) else{return .refused("fn only works with other modifier keys, like fn ⌃.")}
        guard !modifiers.isDisjoint(with:[.control,.option]) else{return .refused("Include ⌃ or ⌥, so it doesn’t clash with typing or other apps.")}
        return .shortcut(PointerShortcut(modifiers:modifiers,key:key,keyName:name))
    }
    static func load(from defaults:UserDefaults)->PointerShortcut {
        guard let stored=defaults.dictionary(forKey:storageKey),let raw=stored["modifiers"] as? UInt else{return .fnControl}
        let result=recorded(NSEvent.ModifierFlags(rawValue:raw),key:(stored["key"] as? Int).map{UInt16($0)},name:stored["name"] as? String)
        if case .shortcut(let shortcut)=result{return shortcut}
        return .fnControl
    }
    func save(to defaults:UserDefaults) {
        var stored:[String:Any]=["modifiers":modifiers.rawValue]
        if let key{stored["key"]=Int(key)}
        if let keyName{stored["name"]=keyName}
        defaults.set(stored,forKey:Self.storageKey)
    }
    fileprivate static func adopt(_ shortcut:PointerShortcut){current=shortcut;shortcut.save(to:.standard)}
}

// Listens for the current shortcut: modifiers alone through NotchShortcut, a key through a system hot key, since fn can't be one.
final class PointerShortcutKeys {
    static let shared=PointerShortcutKeys()
    private var hotKey:EventHotKeyRef?,modifierKeys:NotchShortcut?
    // Set while recording, so pressing the old shortcut doesn't also act on it.
    var suspended=false{didSet{deactivate();if !suspended{_=activate(PointerShortcut.current)}}}

    func install(pressed:@escaping()->Void) {
        var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{_,_,_ in PointerShortcutKeys.shared.modifierKeys?.press();return noErr},1,&type,nil,nil)
        modifierKeys=NotchShortcut(pressed:pressed)
        if !activate(PointerShortcut.current){PointerShortcut.adopt(.fnControl);_=activate(.fnControl)}
    }
    // False, with the old shortcut still working, when another app holds the keys.
    func set(_ shortcut:PointerShortcut)->Bool {
        deactivate()
        guard activate(shortcut) else{
            if !suspended{_=activate(PointerShortcut.current)}
            return false
        }
        PointerShortcut.adopt(shortcut)
        if suspended{deactivate()}
        return true
    }
    private func activate(_ shortcut:PointerShortcut)->Bool {
        guard let key=shortcut.key else{modifierKeys?.watched=shortcut.modifiers;return true}
        var next:EventHotKeyRef?
        let status=RegisterEventHotKey(UInt32(key),shortcut.carbonModifiers,EventHotKeyID(signature:0x41505054,id:1),GetApplicationEventTarget(),0,&next)
        guard status==noErr,let next else{return false}
        hotKey=next
        return true
    }
    private func deactivate() {
        modifierKeys?.watched=nil
        if let hotKey{UnregisterEventHotKey(hotKey);self.hotKey=nil}
    }
}

// The Settings control: click the shortcut, then press the new one. esc or clicking elsewhere keeps the old one.
final class PointerShortcutControl:NSStackView {
    static let guidance="Works from any app. It also connects your AirPods when they aren’t connected. Click the shortcut to change it."
    let note=rkWrap(guidance,12)
    private lazy var button=RemoteButton(PointerShortcut.current.label,style:.secondary,height:32,target:self,action:#selector(begin))
    private lazy var reset=RemoteButton("Reset",style:.tertiary,height:32,target:self,action:#selector(resetPressed))
    private var monitor:Any?,resignObserver:Any?,peak:NSEvent.ModifierFlags=[],waitForRelease=false

    init() {
        super.init(frame:.zero)
        translatesAutoresizingMaskIntoConstraints=false;orientation = .horizontal;spacing=8
        addArrangedSubview(reset);addArrangedSubview(button)
        refresh()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    deinit{stopListening()}

    private func refresh() {
        let current=PointerShortcut.current
        button.title=current.label;button.setAccessibilityLabel("Change shortcut, currently \(current.spoken)")
        reset.isHidden=current == .fnControl
        rkSetText(note,Self.guidance)
    }
    @objc private func begin() {
        guard monitor==nil else{return}
        PointerShortcutKeys.shared.suspended=true
        peak=[];waitForRelease=false
        button.title="Press keys…";button.setAccessibilityLabel("Waiting for the new shortcut")
        rkSetText(note,"Press the new shortcut, or esc to keep the old one.")
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.flagsChanged,.leftMouseDown]){[weak self] event in self?.handle(event) ?? event}
        resignObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main){[weak self] _ in self?.finish()}
    }
    @objc private func resetPressed(){if PointerShortcutKeys.shared.set(.fnControl){refresh()}}
    private func handle(_ event:NSEvent)->NSEvent? {
        let flags=event.modifierFlags.intersection(PointerShortcut.relevant)
        switch event.type {
        case .leftMouseDown:finish();return event
        case .flagsChanged:
            if waitForRelease{waitForRelease = !flags.isEmpty;return event}
            peak.formUnion(flags)
            if flags.isEmpty,!peak.isEmpty{take(PointerShortcut.recorded(peak));peak=[]}
            return event
        case .keyDown where !event.isARepeat:
            if event.keyCode==UInt16(kVK_Escape),flags.isEmpty{finish();return nil}
            waitForRelease = !flags.isEmpty;peak=[]
            take(PointerShortcut.recorded(flags,key:event.keyCode,name:Self.name(of:event),special:event.specialKey != nil))
            return nil
        default:return nil
        }
    }
    private func take(_ result:PointerShortcut.Recorded) {
        switch result {
        case .refused(let reason):rkSetText(note,reason)
        case .shortcut(let shortcut):
            if PointerShortcutKeys.shared.set(shortcut){finish()}
            else{rkSetText(note,"Another app is using that shortcut. Try another, or esc to keep the old one.")}
        }
    }
    private func finish() {
        stopListening()
        PointerShortcutKeys.shared.suspended=false
        refresh()
    }
    private func stopListening() {
        if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil}
        if let resignObserver{NotificationCenter.default.removeObserver(resignObserver);self.resignObserver=nil}
    }
    private static func name(of event:NSEvent)->String {
        switch Int(event.keyCode) {
        case kVK_Space:return "Space"
        case kVK_Return,kVK_ANSI_KeypadEnter:return "Return"
        case kVK_Tab:return "Tab"
        case kVK_Delete:return "Delete"
        case kVK_ForwardDelete:return "Forward Delete"
        case kVK_LeftArrow:return "←"
        case kVK_RightArrow:return "→"
        case kVK_UpArrow:return "↑"
        case kVK_DownArrow:return "↓"
        default:break
        }
        if let special=event.specialKey,let number=(1...20).first(where:{NSEvent.SpecialKey(rawValue:NSF1FunctionKey+$0-1)==special}){return "F\(number)"}
        let text=event.characters(byApplyingModifiers:[])?.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() ?? ""
        return text.isEmpty ? "Key \(event.keyCode)":text
    }
}
