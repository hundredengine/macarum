import Foundation

/// Recognises a modifier key tapped several times in a row on its own (for example ⌘ ⌘ ⌘).
/// Any other key or modifier in between starts the count again, so ⌘C, ⌘V and friends
/// never add up to a trigger.
public struct TapDetector: Sendable {
    /// What the modifier keys look like after a change.
    public enum Modifiers: Sendable {
        case none
        /// Only the watched modifier is down.
        case onlyTarget
        /// Anything else, alone or together with the watched one.
        case other
    }

    public let tapsNeeded: Int
    /// The key has to come back up this soon to count as a tap rather than a hold.
    public let maxHold: TimeInterval
    /// Longest pause between one tap ending and the next one ending.
    public let maxGap: TimeInterval

    private var isDown = false
    private var downAt: TimeInterval = 0
    private var count = 0
    private var lastTapAt: TimeInterval = -.infinity

    public init(tapsNeeded: Int = 3, maxHold: TimeInterval = 0.3, maxGap: TimeInterval = 0.4) {
        self.tapsNeeded = tapsNeeded
        self.maxHold = maxHold
        self.maxGap = maxGap
    }

    /// Feed every modifier change. Returns true on the tap that completes the sequence.
    public mutating func modifiersChanged(to modifiers: Modifiers, at time: TimeInterval) -> Bool {
        switch modifiers {
        case .onlyTarget:
            if !isDown {
                isDown = true
                downAt = time
            }
            return false
        case .none:
            guard isDown else { return false }
            isDown = false
            guard time - downAt <= maxHold else {
                reset()
                return false
            }
            if time - lastTapAt > maxGap { count = 0 }
            count += 1
            lastTapAt = time
            if count >= tapsNeeded {
                reset()
                return true
            }
            return false
        case .other:
            reset()
            return false
        }
    }

    /// Feed every key press. A real key in between means this was a shortcut, not a tap.
    public mutating func keyPressed() {
        reset()
    }

    private mutating func reset() {
        isDown = false
        count = 0
        lastTapAt = -.infinity
    }
}
