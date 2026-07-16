import AppKit

@MainActor
protocol CaptureSoundPlaying: AnyObject {
    func playCaptureSound()
}

@MainActor
final class SystemCaptureSoundPlayer: CaptureSoundPlaying {
    private let sound: NSSound?

    init() {
        let shutterPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif"
        let sound = NSSound(contentsOfFile: shutterPath, byReference: true)
            ?? NSSound(named: NSSound.Name("Tink"))
        sound?.volume = 0.16
        self.sound = sound
    }

    func playCaptureSound() {
        guard let sound else { return }
        sound.stop()
        sound.currentTime = 0
        sound.play()
    }
}
