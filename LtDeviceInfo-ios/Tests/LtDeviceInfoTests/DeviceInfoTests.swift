import Testing
@testable import LtDeviceInfo

@Test func accessoryNamesLoseTheOwner() {
    #expect(DeviceInfo.deviceModel("Jason's AirPods Pro") == "AirPods Pro")
    #expect(DeviceInfo.deviceModel("Jason’s AirPods Pro") == "AirPods Pro")
    #expect(DeviceInfo.deviceModel("小明的 AirPods") == "AirPods")
    #expect(DeviceInfo.deviceModel("WH-1000XM5") == "WH-1000XM5")
    #expect(DeviceInfo.deviceModel(nil) == "")
}

@Test func audioPortsMapToContractRoutes() {
    #expect(DeviceInfo.audioRoute(port: "Speaker", name: "Speaker") == AudioRoute(route: "speaker"))
    #expect(DeviceInfo.audioRoute(port: "Receiver", name: "Receiver") == AudioRoute(route: "earpiece"))
    #expect(DeviceInfo.audioRoute(port: "Headphones", name: "Headphones") == AudioRoute(route: "wired"))
    #expect(DeviceInfo.audioRoute(port: "BluetoothHFP", name: "小明的 AirPods Pro") == AudioRoute(route: "bluetooth", device: "AirPods Pro", btProfile: "hfp"))
    #expect(DeviceInfo.audioRoute(port: "BluetoothA2DPOutput", name: "WH-1000XM5") == AudioRoute(route: "bluetooth", device: "WH-1000XM5", btProfile: "a2dp"))
    #expect(DeviceInfo.audioRoute(port: "BluetoothLE", name: nil) == AudioRoute(route: "bluetooth", btProfile: "le_audio"))
    #expect(DeviceInfo.audioRoute(port: "CarAudio", name: "Car") == AudioRoute())
}

@Test func cellularGenerationFromRadioNames() {
    #expect(DeviceInfo.cellularGeneration(radio: "CTRadioAccessTechnologyNR") == "5g")
    #expect(DeviceInfo.cellularGeneration(radio: "CTRadioAccessTechnologyNRNSA") == "5g")
    #expect(DeviceInfo.cellularGeneration(radio: "CTRadioAccessTechnologyLTE") == "4g")
    #expect(DeviceInfo.cellularGeneration(radio: "CTRadioAccessTechnologyWCDMA") == "3g")
    #expect(DeviceInfo.cellularGeneration(radio: "CTRadioAccessTechnologyEdge") == "2g")
    #expect(DeviceInfo.cellularGeneration(radio: nil) == "cellular")
}

@Test func cellularRadioFollowsTheDataLine() {
    let lte = "CTRadioAccessTechnologyLTE", nr = "CTRadioAccessTechnologyNR", nsa = "CTRadioAccessTechnologyNRNSA"
    let sim1 = "0000000100000001", sim2 = "0000000100000002"
    #expect(DeviceInfo.cellularRadio(radios: [sim1: lte], dataService: sim1) == ("4g", lte))
    #expect(DeviceInfo.cellularRadio(radios: [sim1: nsa], dataService: sim1) == ("5g", nsa))
    #expect(DeviceInfo.cellularRadio(radios: [sim1: lte], dataService: nil) == ("4g", lte))
    // Dual SIM: the data line wins whichever way round.
    #expect(DeviceInfo.cellularRadio(radios: [sim1: lte, sim2: nr], dataService: sim1) == ("4g", lte))
    #expect(DeviceInfo.cellularRadio(radios: [sim1: lte, sim2: nr], dataService: sim2) == ("5g", nr))
    // Dual SIM, data line unknown: only an answer both lines agree on.
    #expect(DeviceInfo.cellularRadio(radios: [sim1: nr, sim2: lte], dataService: nil) == ("cellular", "\(nr) / \(lte)"))
    #expect(DeviceInfo.cellularRadio(radios: [sim1: nsa, sim2: nr], dataService: nil) == ("5g", "\(nsa) / \(nr)"))
    // The data line reports no radio: the other line says nothing about it.
    #expect(DeviceInfo.cellularRadio(radios: [sim2: nr], dataService: sim1) == ("cellular", nr))
    #expect(DeviceInfo.cellularRadio(radios: [:], dataService: nil) == ("cellular", ""))
    #expect(DeviceInfo.cellularRadio(radios: [sim1: ""], dataService: nil) == ("cellular", ""))
}

@Test func osNetTypeAndVpnKeepToContractValues() {
    #expect(OsNetType.normalize("cellular") == "unknown")
    #expect(OsNetType.normalize("other") == "unknown")
    #expect(OsNetType.normalize(DeviceInfo.cellularGeneration(radio: "CTRadioAccessTechnologyNRNSA")) == "5g")
    #expect(OsNetType.normalize("wifi") == "wifi")
    #expect(VpnState.from(proxySettings: nil) == "")
    #expect(VpnState.from(proxySettings: ["HTTPEnable": 0]) == "0")
    #expect(VpnState.from(proxySettings: ["__SCOPED__": ["en0": [:], "pdp_ip0": [:]] as [String: Any]]) == "0")
    #expect(VpnState.from(proxySettings: ["__SCOPED__": ["en0": [:], "utun3": [:]] as [String: Any]]) == "1")
    #expect(VpnState.from(proxySettings: ["__SCOPED__": ["ipsec0": [:]] as [String: Any]]) == "1")
}

@Test func thermalInterruptionAndLaunchRules() {
    #expect((0...3).map { Thermal.ios($0) } == [0, 1, 2, 3])
    #expect(Thermal.ios(7) == nil)
    #expect((0...6).map { Thermal.android($0) } == [0, 1, 1, 2, 3, 3, 3])
    #expect((0...3).map(Thermal.name) == ["nominal", "fair", "serious", "critical"])
    #expect(AudioInterruption.silences(began: true, reason: "default"))
    #expect(!AudioInterruption.silences(began: true, reason: "appWasSuspended"))
    #expect(!AudioInterruption.silences(began: false, reason: "default"))
    var launch = AppLaunchTracker()
    #expect(launch.classify(foreground: false) == AppLaunch.cold)
    #expect(launch.classify(foreground: false) == AppLaunch.background)
    #expect(launch.classify(foreground: true) == AppLaunch.foreground)
}
