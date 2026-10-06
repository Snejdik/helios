import Foundation

// Read-only fan/thermal sampler for scripts/watch-fan-layer.sh.
// Uses only SMC read commands (keyInfo/bytes); there is no write path here.
// Usage: FanLayerWatch <seconds> <interval-seconds> <csv-path>

let arguments = CommandLine.arguments
guard arguments.count == 4, let seconds = Double(arguments[1]), let interval = Double(arguments[2]),
      seconds > 0, interval >= 0.5 else {
    FileHandle.standardError.write(Data("Usage: FanLayerWatch <seconds> <interval> <csv>\n".utf8))
    exit(2)
}
let csvPath = arguments[3]

let client = SMCClient(transport: try SMCIOKitTransport())
let reader = SMCFanReader(client: client)
let fanCount = try FanCodec.count(client.value("FNum"))
let thermalKeys = FanLayerTrustedThermals.m4PerformanceCPU
    .union(FanLayerTrustedThermals.m4EfficiencyCPU)
    .union(FanLayerTrustedThermals.m4GPU)
    .sorted()
    .filter { (try? client.keyInfo($0)) != nil }

var header = "time,elapsed_s,ftst"
for id in 0..<fanCount { header += ",f\(id)_mode,f\(id)_target,f\(id)_actual" }
header += ",max_soc_c\n"
FileManager.default.createFile(atPath: csvPath, contents: Data(header.utf8))
guard let output = FileHandle(forWritingAtPath: csvPath) else { exit(1) }
output.seekToEndOfFile()

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss"
let started = Date()
var stopping = false
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { stopping = true }
interrupt.activate()

func sample() {
    let elapsed = Date().timeIntervalSince(started)
    var row = "\(formatter.string(from: Date())),\(String(format: "%.1f", elapsed))"
    row += "," + ((try? client.value("Ftst").bytes.first).flatMap { $0 }.map(String.init) ?? "")
    for id in 0..<fanCount {
        let mode = (try? reader.mode(id)).map(String.init) ?? ""
        let target = (try? reader.rpm(id, "Tg")).map { String(Int($0.rounded())) } ?? ""
        let actual = (try? reader.rpm(id, "Ac")).map { String(Int($0.rounded())) } ?? ""
        row += ",\(mode),\(target),\(actual)"
    }
    var hottest: Double?
    for key in thermalKeys {
        guard let value = try? client.value(key),
              let celsius = try? SMCCodec.temperature(type: value.info.type, bytes: value.bytes),
              (5.0...130.0).contains(celsius) else { continue }
        hottest = max(hottest ?? celsius, celsius)
    }
    row += "," + (hottest.map { String(format: "%.1f", $0) } ?? "") + "\n"
    output.write(Data(row.utf8))
}

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: interval)
timer.setEventHandler {
    if stopping || Date().timeIntervalSince(started) >= seconds {
        output.closeFile()
        exit(0)
    }
    sample()
}
timer.activate()
dispatchMain()
