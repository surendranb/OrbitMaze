// Gravity-vector → tilt mapping with per-level calibration.
// Pure Swift (no Foundation, no CoreMotion) so it type-checks with plain
// `swiftc` and can be unit-tested without a watch.
//
// Pipeline (called once per motion sample):
//   1. Orientation: the device-frame gravity (x, y) is rotated into the
//      screen frame. See `ScreenOrientation` for the wrist/crown rationale.
//   2. Calibration: for the first `calibrationDuration` seconds after
//      `beginCalibration()` samples are averaged; the mean becomes `neutral`.
//      Output is zero while calibrating.
//   3. Delta: d = screenGravity − neutral. For small angles the component of
//      gravity along a screen axis ≈ sin(tilt angle about the other axis), so
//      d is a direct (unit-less) tilt measure.
//   4. Dead zone + scaling, applied radially so direction is preserved:
//      |d| ≤ sin(deadZone°)  → 0
//      |d| ≥ sin(fullTilt°)  → magnitude 1
//      otherwise linear in between.
//   5. First-order low-pass filter with time constant `smoothing` (s).
//   6. Clamp |output| ≤ 1.
//
// Output frame = maze frame: +x right, +y UP (the view flips y when drawing).
// Tilting the screen's right edge down → gravity.x > 0 → ball rolls right.
// Tilting the screen's top edge down   → gravity.y > 0 → ball rolls up.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// How the hardware motion axes relate to what the user sees.
///
/// Apple Watch device axes (CoreMotion): +x points toward the Digital Crown
/// side of the case, +y toward the 12 o'clock edge, +z out of the display.
/// watchOS lets the user wear the watch with the crown on the LEFT: the case is
/// physically rotated 180° in the display plane and watchOS rotates the UI by
/// 180° so text stays upright. The sensor frame does NOT rotate with the UI,
/// so for crown-left both screen axes are the negation of the device axes.
/// Wrist location (left/right wrist) on its own does not change this
/// relation; only the crown side does.
///
/// VERIFY: that CMDeviceMotion on watchOS reports in the fixed case frame and
/// does not already compensate for crown orientation. If a crown-left user
/// finds the ball rolls away from the tilt, the `Invert tilt` toggle on the
/// Home screen is the manual fix.
public enum ScreenOrientation: Sendable {
    /// Crown on the right side of the display (default). Screen axes == device axes.
    case crownRight
    /// Crown on the left side. Screen axes == −device axes.
    case crownLeft
}

public struct TiltMapper: Sendable {
    /// Tilt angle (degrees) that yields full magnitude 1.
    public var fullTiltDegrees: Double
    /// Tilt angle (degrees) below which output is 0.
    public var deadZoneDegrees: Double
    /// Low-pass time constant (s). 0 disables smoothing.
    public var smoothing: Double
    /// Seconds of samples averaged to find the neutral pose.
    public var calibrationDuration: Double
    public var orientation: ScreenOrientation
    /// User override: negate both axes (fix for an unexpected sensor frame).
    public var invert: Bool

    public private(set) var output: Vec2 = .zero
    public private(set) var neutral: Vec2 = .zero
    public private(set) var isCalibrating = false

    private var calibrationSum = Vec2.zero
    private var calibrationTime = 0.0
    private var calibrationSamples = 0

    public init(
        fullTiltDegrees: Double = 15,
        deadZoneDegrees: Double = 2,
        smoothing: Double = 0.05,
        calibrationDuration: Double = 0.5,
        orientation: ScreenOrientation = .crownRight,
        invert: Bool = false
    ) {
        self.fullTiltDegrees = fullTiltDegrees
        self.deadZoneDegrees = deadZoneDegrees
        self.smoothing = smoothing
        self.calibrationDuration = calibrationDuration
        self.orientation = orientation
        self.invert = invert
    }

    /// Stop calibrating now. Uses whatever samples arrived; keeps the old
    /// neutral if none did (guards against a sensor that never delivers).
    public mutating func cancelCalibration() {
        if calibrationSamples > 0 {
            neutral = calibrationSum * (1.0 / Double(calibrationSamples))
        }
        isCalibrating = false
        output = .zero
    }

    /// Start averaging samples for a new neutral pose. Output is zero until done.
    public mutating func beginCalibration() {
        isCalibrating = true
        calibrationSum = .zero
        calibrationTime = 0
        calibrationSamples = 0
        output = .zero
    }

    /// Feed one gravity sample (device frame, unit-ish vector) with the time
    /// since the previous sample. Returns the new tilt in the maze frame.
    @discardableResult
    public mutating func ingest(gravityX gx: Double, gravityY gy: Double, dt: Double) -> Vec2 {
        var g = Vec2(gx, gy)
        if orientation == .crownLeft { g = g * -1 }
        if invert { g = g * -1 }

        if isCalibrating {
            calibrationSum = calibrationSum + g
            calibrationSamples += 1
            calibrationTime += max(0, dt)
            if calibrationTime >= calibrationDuration, calibrationSamples >= 3 {
                neutral = calibrationSum * (1.0 / Double(calibrationSamples))
                isCalibrating = false
            }
            output = .zero
            return output
        }

        let d = g - neutral
        let m = d.length
        let dead = sin(deadZoneDegrees * Double.pi / 180)
        let full = sin(fullTiltDegrees * Double.pi / 180)
        var target = Vec2.zero
        if m > dead, full > dead {
            let k = min(1.0, (m - dead) / (full - dead))
            target = d * (k / m)
        }

        if smoothing > 0, dt > 0 {
            let alpha = 1 - exp(-dt / smoothing)
            output = output + (target - output) * alpha
        } else {
            output = target
        }
        let len = output.length
        if len > 1 { output = output * (1 / len) }
        return output
    }

    /// Drop the current filter state (e.g. on resume) without touching `neutral`.
    public mutating func resetFilter() { output = .zero }
}
