import CarPlay
import Combine

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var listTemplate:        CPListTemplate?
    private var cancellable:         AnyCancellable?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        let template = CPListTemplate(title: "Minify Radio", sections: [makeSection()])
        listTemplate = template
        interfaceController.setRootTemplate(template, animated: true, completion: nil)

        updateNowPlayingButtons()

        // Refresh rows (playing indicator, station swaps) whenever the engine changes
        // (main-queue hop so @Published values are updated when we read them).
        cancellable = RadioEngine.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let template = self.listTemplate else { return }
                template.updateSections([self.makeSection()])
                self.updateNowPlayingButtons()
            }
    }

    /// Star on the Now Playing screen — favorites the identified track in Apple Music.
    private func updateNowPlayingButtons() {
        let engine = RadioEngine.shared
        guard engine.trackID != nil,
              let image = UIImage(systemName: engine.currentTrackFavorited ? "star.fill" : "star")
        else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }
        let star = CPNowPlayingImageButton(image: image) { _ in
            RadioEngine.shared.toggleFavoriteCurrentTrack()
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([star])
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        cancellable = nil
        listTemplate = nil
        self.interfaceController = nil
    }

    private func makeSection() -> CPListSection {
        let engine   = RadioEngine.shared
        let maxSize  = CPListItem.maximumImageSize
        let tileSide = min(maxSize.width, maxSize.height) > 0
            ? min(maxSize.width, maxSize.height) : 80
        let items: [CPListItem] = engine.stations.map { station in
            let item = CPListItem(text: station.name,
                                  detailText: station.tagline,
                                  image: WaveArt.tile(for: station, side: tileSide))
            item.playingIndicatorLocation = .trailing
            item.isPlaying = engine.isPlaying && engine.currentStation?.id == station.id
            item.handler = { [weak self] _, completion in
                RadioEngine.shared.play(station)
                self?.pushNowPlaying()
                completion()
            }
            return item
        }
        return CPListSection(items: items)
    }

    private func pushNowPlaying() {
        guard let ic = interfaceController,
              !(ic.topTemplate is CPNowPlayingTemplate) else { return }
        ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
