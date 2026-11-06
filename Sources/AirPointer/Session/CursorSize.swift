import Foundation

// A small cursor is hard to follow while aiming, so it grows while the case is pointing and goes back afterwards. One already
// larger is left alone. macOS has no public way to do this, so the calls are looked up at run time and do nothing if a later
// macOS drops them. The size outlives the app, so the one to go back to is saved, and a crash is put right at the next launch.
final class CursorSize {
    static let shared=CursorSize()
    static let pointing:Float=2
    private static let savedKey="cursorSizeToRestore"
    private typealias Connection=@convention(c)()->Int32
    private typealias Getter=@convention(c)(Int32,UnsafeMutablePointer<Float>)->Int32
    private typealias Setter=@convention(c)(Int32,Float)->Int32
    private let connection=CursorSize.symbol("CGSMainConnectionID",as:Connection.self)
    private let getter=CursorSize.symbol("CGSGetCursorScale",as:Getter.self)
    private let setter=CursorSize.symbol("CGSSetCursorScale",as:Setter.self)

    private static func symbol<T>(_ name:String,as type:T.Type)->T? {
        dlsym(UnsafeMutableRawPointer(bitPattern:-2),name).map{unsafeBitCast($0,to:type)}
    }
    static func grown(from current:Float)->Float?{current<pointing-0.01 ? pointing:nil}
    // Only if it's still the size set here: they may have changed it in System Settings since.
    static func restored(_ saved:Float,current:Float)->Float?{abs(current-pointing)<0.01 ? saved:nil}

    func pointingChanged(_ on:Bool){if on{grow()}else{restore()}}
    func restore() {
        let defaults=UserDefaults.standard
        guard let saved=defaults.object(forKey:Self.savedKey) as? Double else{return}
        defaults.removeObject(forKey:Self.savedKey)
        if let current=size(),let next=Self.restored(Float(saved),current:current){set(next)}
    }
    private func grow() {
        guard UserDefaults.standard.object(forKey:Self.savedKey)==nil,let current=size(),let next=Self.grown(from:current) else{return}
        UserDefaults.standard.set(Double(current),forKey:Self.savedKey)
        set(next)
    }
    private func size()->Float? {
        guard let connection,let getter else{return nil}
        var value:Float=0
        return getter(connection(),&value)==0 ? value:nil
    }
    private func set(_ value:Float){if let connection,let setter{_=setter(connection(),value)}}
}
