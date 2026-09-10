import Foundation

enum TelemetryError: Error, Equatable, Sendable, LocalizedError {
    case unavailable(String)
    case invalidData(String)
    case kernel(String, Int32)
    case ioKit(String, Int32)
    case smc(String, UInt8)
    case warmingUp

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .invalidData(let reason): return reason
        case .kernel(let operation, let code): return "\(operation) failed (\(code))"
        case .ioKit(let operation, let code): return "\(operation) failed (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .smc(let key, let code): return "SMC \(key) unavailable (0x\(String(code, radix: 16)))"
        case .warmingUp: return "Waiting for a sampling interval"
        }
    }
}

typealias MetricResult<Value: Sendable> = Result<Value, TelemetryError>

func captureMetric<Value: Sendable>(_ read: () throws -> Value) -> MetricResult<Value> {
    do { return .success(try read()) }
    catch let error as TelemetryError { return .failure(error) }
    catch { return .failure(.unavailable(error.localizedDescription)) }
}

struct MetricSample<Value: Sendable>: Sendable {
    let result: MetricResult<Value>
    let capturedAt: Date
    // Same host-wide clock in app and daemon, including system sleep. This is
    // captured before acquisition, not when a cached sample is displayed.
    let capturedTicks: UInt64

    init(_ result: MetricResult<Value>, capturedAt: Date = Date(), capturedTicks: UInt64 = HostClock.now) {
        self.result = result
        self.capturedAt = capturedAt
        self.capturedTicks = capturedTicks
    }
}

enum HostClock {
    static var now: UInt64 { mach_continuous_time() }
    static func seconds(from earlier: UInt64, to later: UInt64) -> Double {
        guard later >= earlier else { return -.infinity }
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return .infinity }
        return Double(later - earlier) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
