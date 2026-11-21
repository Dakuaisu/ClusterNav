extension AppModel {
    func previewSavedPlace(_ shortcut: Shortcut) -> String? {
        guard recoveryOffer == nil, ride == nil else {
            return "Finish or discard your unfinished ride before opening another route."
        }
        switch stage {
        case .choosing, .failed:
            break
        default:
            return "Finish or cancel the current route before opening another route."
        }

        let place = shortcut == .home ? places.home : places.work
        guard let place else {
            selectedTab = .ride
            return shortcut == .home
                ? "Set Home when you confirm a destination on the Ride screen."
                : "Set Work when you confirm a destination on the Ride screen."
        }
        selectedTab = .ride
        linkMessage = nil
        navigate(to: place)
        return nil
    }
}
