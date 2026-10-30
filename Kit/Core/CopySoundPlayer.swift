import AVFoundation

/// Plays the four bundled copy-feedback MP3s. Keeps the player alive for the clip duration.
@MainActor
final class CopySoundPlayer {
    private var player: AVAudioPlayer?

    func play(_ effect: CopySoundEffect) {
        guard let url = Bundle.main.url(forResource: effect.resourceName, withExtension: "mp3")
        else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = 0.85
            player.play()
            self.player = player
        } catch {
            self.player = nil
        }
    }
}
