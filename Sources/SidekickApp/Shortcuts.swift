import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens and closes the panel. ⌥⌘Space: free on a stock Mac (Spotlight's Finder search is the only
    /// default user, and it is off when Spotlight is moved), and next to ⌘Space for launchers.
    static let togglePanel = Self("togglePanel", initial: .init(.space, modifiers: [.command, .option]))
}
