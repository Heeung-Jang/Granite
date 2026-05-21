import Foundation

public enum OpenDispositionResolver {
    public static func resolve(isCommandPressed: Bool) -> WorkspaceTabOpenDisposition {
        isCommandPressed ? .newTab : .currentTab
    }
}
