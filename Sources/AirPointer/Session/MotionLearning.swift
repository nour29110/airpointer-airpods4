import Foundation

struct V3 {
    var x: Double; var y: Double; var z: Double
    static let zero = V3(x: 0, y: 0, z: 0)
    var length: Double { sqrt(dot(self)) }
    func dot(_ b: V3) -> Double { x*b.x + y*b.y + z*b.z }
    static func * (a: V3, b: Double) -> V3 { V3(x: a.x*b, y: a.y*b, z: a.z*b) }
}
struct Pose {
    var w: Double; var x: Double; var y: Double; var z: Double
    init(w: Double, x: Double, y: Double, z: Double) { self.w=w; self.x=x; self.y=y; self.z=z }
    var inverse: Pose { Pose(w:w, x:-x, y:-y, z:-z) }
    func dot(_ b: Pose) -> Double { w*b.w + x*b.x + y*b.y + z*b.z }
    func multiplied(by b: Pose) -> Pose {
        Pose(w:w*b.w-x*b.x-y*b.y-z*b.z, x:w*b.x+x*b.w+y*b.z-z*b.y,
             y:w*b.y-x*b.z+y*b.w+z*b.x, z:w*b.z+x*b.y-y*b.x+z*b.w)
    }
    func rotation(from center: Pose) -> V3 {
        var q = center.inverse.multiplied(by: self)
        if q.w < 0 { q = Pose(w:-q.w, x:-q.x, y:-q.y, z:-q.z) }
        let s = sqrt(q.x*q.x+q.y*q.y+q.z*q.z)
        guard s > 1e-8 else { return .zero }
        return V3(x:q.x, y:q.y, z:q.z) * (2*atan2(s, max(0, q.w))/s)
    }
    static func mean(_ poses: [Pose]) -> Pose? {
        guard let first = poses.first else { return nil }
        var total = [0.0, 0.0, 0.0, 0.0]
        for p in poses {
            let sign = p.dot(first) < 0 ? -1.0 : 1.0
            total[0] += sign*p.w; total[1] += sign*p.x; total[2] += sign*p.y; total[3] += sign*p.z
        }
        let n = sqrt(total.reduce(0) { $0 + $1*$1 })
        guard n > 1e-8 else { return nil }
        return Pose(w:total[0]/n, x:total[1]/n, y:total[2]/n, z:total[3]/n)
    }
}
enum LessonError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text)=self { return text }; return nil }
}
struct MotionFrame {
    let t: Double
    let pose: Pose
}
