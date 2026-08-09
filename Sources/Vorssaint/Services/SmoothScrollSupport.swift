// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Pure math for smooth mouse-wheel scrolling, kept free of AppKit so the
/// unit harness can pin it.
///
/// Each wheel impulse grows a per-axis remaining budget. Every animation
/// frame then emits a fraction α of what is left (exponential ease-out), so
/// the jump decays into a longer coast that slows as it lands — the same
/// family of motion used by dedicated smooth-scroll tools, tuned here with
/// step, speed and duration.
enum SmoothScrollSupport {
    struct Axes: Equatable {
        let vertical: Double
        let horizontal: Double
    }

    /// Animation frame length. Sixty steps a second reads as continuous and
    /// stays far below what event posting can sustain.
    static let frameInterval: TimeInterval = 1.0 / 60.0

    /// Residuals smaller than this are flushed (or stop the glide) so float
    /// dust never keeps the timer alive.
    static let deadZone: Double = 1.0

    /// Must sit a hair above the duration slider's maximum so α never hits
    /// zero at the top of the range.
    static let durationUpperLimit: Double = 5.2

    /// Base distance of one wheel tick before speed is applied, in pixels.
    static let stepRange = 10...100
    static let defaultStep = 34

    /// Multiplier on each impulse. Higher means more distance per notch.
    static let speedRange: ClosedRange<Double> = 1.0...10.0
    static let defaultSpeed: Double = 2.7

    /// How long the coast feels. Higher → smaller α → softer, longer glide.
    static let durationRange: ClosedRange<Double> = 1.0...5.0
    static let defaultDuration: Double = 4.35

    /// The tick count of a discrete wheel event. High-resolution wheels
    /// report fractions of a line in the fixed-point field while the integer
    /// field truncates to zero, so the fixed-point value wins when present.
    static func ticks(line: Double, fixedPoint: Double) -> Double {
        fixedPoint != 0 ? fixedPoint : line
    }

    /// Maps the duration slider onto the per-frame lerp factor α.
    /// `α = 1 - sqrt(duration / upperLimit)`.
    static func transition(forDuration duration: Double) -> Double {
        let d = sanitizedDuration(duration)
        let alpha = 1 - (d / durationUpperLimit).squareRoot()
        guard alpha.isFinite else { return transition(forDuration: defaultDuration) }
        return (alpha * 1000).rounded() / 1000
    }

    /// Pixel distance a continuous wheel event reports before speed. The
    /// whole-point field is already in points and is what apps themselves
    /// read; the fixed-point field counts lines and only comes in when the
    /// driver left the point field empty.
    static func continuousBase(fixedPointDelta: Double, pointDelta: Double) -> Double {
        guard fixedPointDelta.isFinite, pointDelta.isFinite else { return 0 }
        return pointDelta != 0
            ? pointDelta
            : fixedPointDelta * ScrollWheelSupport.pointsPerLine
    }

    /// Distance added to the glide budget for one wheel reading. Values
    /// smaller than `step` are raised to it so weak notches still travel a
    /// full stride, then speed stretches the result.
    static func impulse(delta: Double, step: Double, speed: Double) -> Double {
        guard delta.isFinite, delta != 0 else { return 0 }
        let stepValue = Double(sanitizedStep(Int(step.rounded())))
        let speedValue = sanitizedSpeed(speed)
        let usable = abs(delta) < stepValue
            ? (delta < 0 ? -stepValue : stepValue)
            : delta
        let result = usable * speedValue
        return result.isFinite ? result : 0
    }

    /// Convenience for the continuous path: base points, then the same
    /// step floor and speed gain as a discrete tick.
    static func continuousImpulse(fixedPointDelta: Double,
                                  pointDelta: Double,
                                  step: Double,
                                  speed: Double) -> Double {
        impulse(delta: continuousBase(fixedPointDelta: fixedPointDelta,
                                      pointDelta: pointDelta),
                step: step,
                speed: speed)
    }

    /// Splits a frame's distance into whole pixels to post and the fraction
    /// to carry into the next one. Rounding each frame on its own would drop
    /// up to half a pixel every time, which a fine-grained wheel feels as
    /// distance that never arrives.
    static func wholePixels(_ distance: Double, carry: Double) -> (pixels: Double, carry: Double) {
        let total = distance + carry
        guard total.isFinite else { return (0, 0) }
        let whole = total.rounded(.towardZero)
        return (whole, total - whole)
    }

    /// The last frame of a glide rounds its leftover out instead of carrying
    /// it forward, because there is no next frame to spend it in.
    static func finalPixels(_ distance: Double, carry: Double) -> Double {
        let total = distance + carry
        guard total.isFinite else { return 0 }
        return total.rounded(.toNearestOrAwayFromZero)
    }

    /// Leftover fractions only help while the glide keeps its direction; a
    /// reversal drops them so the first pixel of the new direction is not
    /// eaten by what the old one left behind.
    static func carry(_ current: Double, continuing distance: Double) -> Double {
        guard distance != 0, current != 0, (distance < 0) != (current < 0) else { return current }
        return 0
    }

    /// The remaining distance after a new impulse. Scrolling the opposite
    /// way abandons what was left instead of fighting it, so a direction
    /// change reacts instantly.
    static func remaining(afterImpulse impulse: Double, current: Double) -> Double {
        guard impulse != 0 else { return current }
        if current != 0, (impulse < 0) != (current < 0) {
            return impulse
        }
        return current + impulse
    }

    /// A vertical wheel tick with Shift held scrolls sideways instead. That
    /// redirect happens above the event tap, so once the original tick is
    /// swallowed the glide has to perform it. A wheel that already reports
    /// a horizontal axis is left alone so its native direction is preserved.
    static func axes(vertical: Double, horizontal: Double, shiftPressed: Bool) -> Axes {
        guard shiftPressed, vertical != 0, horizontal == 0 else {
            return Axes(vertical: vertical, horizontal: horizontal)
        }
        return Axes(vertical: 0, horizontal: vertical)
    }

    /// Distance one frame should emit for this remaining budget: the
    /// exponential slice `remaining * α`, or the whole leftover once it is
    /// inside the dead zone.
    static func frameDelta(remaining: Double, transition: Double) -> Double {
        guard remaining != 0, transition.isFinite, transition > 0 else { return 0 }
        if abs(remaining) <= deadZone { return remaining }
        let emitted = remaining * transition
        return emitted.isFinite ? emitted : 0
    }

    /// True when both the residual and the would-be frame are too small to
    /// bother posting — the glide has landed.
    static func hasLanded(remaining: Double, frame: Double) -> Bool {
        abs(remaining) <= deadZone && abs(frame) <= deadZone
    }

    static func sanitizedStep(_ value: Int) -> Int {
        guard value != 0 else { return defaultStep }
        return min(max(value, stepRange.lowerBound), stepRange.upperBound)
    }

    static func sanitizedSpeed(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultSpeed }
        return min(max(value, speedRange.lowerBound), speedRange.upperBound)
    }

    static func sanitizedDuration(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultDuration }
        return min(max(value, durationRange.lowerBound), durationRange.upperBound)
    }
}
