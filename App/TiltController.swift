import CoreMotion
import Observation
import WatchKit

/// Tilt input source. On a real watch: CMMotionManager device motion
/// (gravity vector) at 60 Hz, fed through `TiltMapper` (calibration, dead
/// zone, scaling, smoothing). In the simulator, or when device motion is
/// unavailable, the game falls back to a drag gesture on the maze; the view
/// writes the drag-derived vector into `manualTilt`.
///
/// Axis mapping (see `ScreenOrientation` in TiltMapper.swift for the full
/// rationale): device +x → screen right, device +y → screen top for the
/// default crown-right wearing position; both negated for crown-left.
/// Output is in the maze frame (+x right, +y up), magnitude ≤ 1.
@MainActor
@Observable
final class TiltController {
    /// True when real motion data drives the game (false in the simulator).
    let usesMotion: Bool

    /// Observed by the view to show "Hold still".
    private(set) var isCalibrating = false

    /// Latest tilt in the maze frame. Read once per frame by the game loop;
    /// not observed to avoid a view invalidation per motion sample.
    @ObservationIgnored private(set) var current = Vec2.zero

    /// Simulator / no-motion input, set by the drag gesture.
    @ObservationIgnored var manualTilt = Vec2.zero

    private let motion = CMMotionManager()
    @ObservationIgnored private var mapper: TiltMapper
    @ObservationIgnored private var lastSampleTimestamp: TimeInterval?
    @ObservationIgnored private var manualCalibrationRemaining = 0.0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var calibrationTimeout = 0.0

    private static let sampleInterval = 1.0 / 60.0
    private static let manualCalibrationSeconds = 0.5
    private static let calibrationTimeoutSeconds = 3.0

    init(sensitivity: Sensitivity, invert: Bool) {
        #if targetEnvironment(simulator)
        usesMotion = false
        #else
        usesMotion = motion.isDeviceMotionAvailable
        #endif

        // Crown side decides whether the sensor frame is rotated 180° relative
        // to the screen. Wrist side alone does not change the mapping.
        let crown = WKInterfaceDevice.current().crownOrientation
        let orientation: ScreenOrientation = (crown == .left) ? .crownLeft : .crownRight

        mapper = TiltMapper(
            fullTiltDegrees: sensitivity.fullTiltDegrees,
            deadZoneDegrees: 2,
            smoothing: 0.05,
            calibrationDuration: Self.manualCalibrationSeconds,
            orientation: orientation,
            invert: invert
        )
    }

    // MARK: Settings

    func apply(sensitivity: Sensitivity) {
        mapper.fullTiltDegrees = sensitivity.fullTiltDegrees
    }

    func apply(invert: Bool) {
        mapper.invert = invert
    }

    /// Drop the low-pass filter state without touching the calibrated neutral.
    /// Called on every resume so a stale pre-sleep sample cannot fling the ball.
    func resetMotionFilter() {
        mapper.resetFilter()
        current = .zero
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        lastSampleTimestamp = nil
        guard usesMotion else { return }
        motion.deviceMotionUpdateInterval = Self.sampleInterval
        // Handler runs on the main queue; `MainActor.assumeIsolated` lets the
        // compiler accept the hop into this @MainActor object without a Task.
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let gx = data.gravity.x
            let gy = data.gravity.y
            let timestamp = data.timestamp
            MainActor.assumeIsolated {
                self?.ingest(gravityX: gx, gravityY: gy, timestamp: timestamp)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if usesMotion { motion.stopDeviceMotionUpdates() }
        current = .zero
        manualTilt = .zero
    }

    // MARK: Calibration

    /// Sample ~0.5 s of gravity and treat the mean as "flat". Call at the start
    /// of every level and after a resume-with-recalibrate.
    func beginCalibration() {
        isCalibrating = true
        mapper.beginCalibration()
        current = .zero
        manualTilt = .zero
        manualCalibrationRemaining = Self.manualCalibrationSeconds
        calibrationTimeout = Self.calibrationTimeoutSeconds
    }

    /// Per-frame hook from the game loop. In manual mode it times the fake
    /// calibration and publishes the drag vector; in motion mode it only
    /// mirrors the calibration flag.
    func tick(dt: Double) {
        if usesMotion {
            if isCalibrating {
                // Never hang on "Hold still" if motion samples stop arriving.
                calibrationTimeout -= dt
                if calibrationTimeout <= 0 { mapper.cancelCalibration() }
                if !mapper.isCalibrating { isCalibrating = false }
            }
            return
        }
        if isCalibrating {
            manualCalibrationRemaining -= dt
            if manualCalibrationRemaining <= 0 { isCalibrating = false }
            current = .zero
            return
        }
        var t = manualTilt
        let m = t.length
        if m > 1 { t = t * (1 / m) }
        current = t
    }

    // MARK: Motion ingest

    private func ingest(gravityX gx: Double, gravityY gy: Double, timestamp: TimeInterval) {
        guard running else { return }
        let dt: Double
        if let last = lastSampleTimestamp {
            dt = min(max(timestamp - last, 0), 0.1)
        } else {
            dt = Self.sampleInterval
        }
        lastSampleTimestamp = timestamp
        current = mapper.ingest(gravityX: gx, gravityY: gy, dt: dt)
        if isCalibrating, !mapper.isCalibrating { isCalibrating = false }
    }
}
