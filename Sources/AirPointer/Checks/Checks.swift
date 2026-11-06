import Foundation
// A failed check names its line. A plain precondition traps with no message in an optimized build.
func selfCheck(_ condition:@autoclosure()->Bool,_ message:String="",file:StaticString=#fileID,line:UInt=#line) {
    guard !condition() else{return}
    fputs("Check failed at \(file):\(line) \(message)\n",stderr);exit(1)
}
func runPoseChecks() {
    func rotation(_ v:V3)->Pose {let a=v.length;guard a>0 else{return Pose(w:1,x:0,y:0,z:0)};let s=sin(a/2)/a;return Pose(w:cos(a/2),x:v.x*s,y:v.y*s,z:v.z*s)}
    let neutral=rotation(V3(x:0.6,y:-0.8,z:1.2))
    let turn=V3(x:0.25,y:0.08,z:-0.03),found=neutral.multiplied(by:rotation(turn)).rotation(from:neutral)
    selfCheck(abs(found.x-turn.x)<1e-7 && abs(found.y-turn.y)<1e-7 && abs(found.z-turn.z)<1e-7)
    let signFlipped=Pose(w:-neutral.w,x:-neutral.x,y:-neutral.y,z:-neutral.z)
    selfCheck(Pose.mean([neutral,signFlipped])!.rotation(from:neutral).length<1e-7)
}
