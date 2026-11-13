/// Manual app opening and external file/Finder requests have separate surfaces.
public enum LaunchPresentation: Equatable {
    case history, service

    public static func startup(isDefaultLaunch: Bool, receivedExternalOpen: Bool, consumedFinderRequest: Bool) -> Self {
        isDefaultLaunch && !receivedExternalOpen && !consumedFinderRequest ? .history : .service
    }
}
