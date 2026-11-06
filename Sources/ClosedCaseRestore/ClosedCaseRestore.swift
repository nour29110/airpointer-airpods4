import Foundation
import IOBluetooth
import CoreBluetooth

// Exit codes, which the app puts in plain words: 0 connected, 2 no readable address,
// 3 the AirPods didn't connect, 4 no Bluetooth access, 5 not paired with this Mac, 6 Bluetooth off.
func normalized(_ value:String)->String{
    value.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"-",with:":").lowercased()
}
guard CommandLine.arguments.count==2,let target=try? String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8) else{
    print("No readable AirPods address.");exit(2)
}
guard CBManager.authorization == .allowedAlways else{print("Bluetooth authorization is unavailable.");exit(4)}
guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else{print("Bluetooth is off.");exit(6)}
guard let paired=IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
      let device=paired.first(where:{normalized($0.addressString ?? "")==normalized(target)}) else{
    print("The AirPods are not paired with this Mac.");exit(5)
}
// A link opened here gets its full 3 s: when the motion helper reconnected it sooner, its channel
// answered but motion never came. A link already up goes straight on.
if !device.isConnected(){
    print(String(format:"Ordinary target connection=0x%08x",device.openConnection()))
    RunLoop.current.run(until:Date().addingTimeInterval(3))
}
let connected=device.isConnected()
print(String(format:"STEP restore finished uptime=%.3f",ProcessInfo.processInfo.systemUptime))
print("Target connected=\(connected)")
exit(connected ? 0:3)
