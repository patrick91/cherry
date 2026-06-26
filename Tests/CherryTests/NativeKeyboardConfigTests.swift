import Foundation
import Testing
@testable import Cherry

private func parsed(_ s: String) -> [String] {
    TerminalSettings.parseUserGhosttyKeyboardConfig(s).map { "\($0.0) = \($0.1)" }
}

@Test func keyboardConfigKeepsShiftEnterAndOptionAsAltFromUserConfig() {
    // The exact lines from a real ghostty config.
    let config = """
    keybind = super+t=new_tab
    keybind = super+enter=toggle_split_zoom
    keybind = shift+enter=text:\\n
    macos-option-as-alt = left
    """
    #expect(parsed(config) == [
        "keybind = shift+enter=text:\\n", // input-producing -> kept
        "macos-option-as-alt = left",     // user's value preserved
        "keybind = shift+tab=csi:Z",      // injected default
    ])
}

@Test func keyboardConfigDropsAppActionKeybinds() {
    let config = """
    keybind = super+t=new_tab
    keybind = cmd+w=close_surface
    keybind = ctrl+a=text:\\x01
    """
    // app actions dropped, text: kept, option-as-alt defaulted on
    #expect(parsed(config) == [
        "keybind = ctrl+a=text:\\x01",
        "keybind = shift+tab=csi:Z",
        "macos-option-as-alt = true",
    ])
}

@Test func keyboardConfigDefaultsOptionAsAltWhenUnset() {
    #expect(parsed("") == ["keybind = shift+tab=csi:Z", "macos-option-as-alt = true"])
    #expect(parsed("font-size = 14\n# a comment") == ["keybind = shift+tab=csi:Z", "macos-option-as-alt = true"])
}

@Test func keyboardConfigDefaultsShiftTabButUserCanOverride() {
    // Default shift+tab is injected when the user has none.
    #expect(parsed("keybind = ctrl+a=text:\\x01").contains("keybind = shift+tab=csi:Z"))
    // A user's own shift+tab binding wins (we don't inject the default).
    let withUserShiftTab = parsed("keybind = shift+tab=text:custom")
    #expect(withUserShiftTab.contains("keybind = shift+tab=text:custom"))
    #expect(!withUserShiftTab.contains("keybind = shift+tab=csi:Z"))
}

@Test func keyboardConfigIgnoresCommentsAndBlankLines() {
    let config = """
    # keyboard
    keybind = shift+enter=text:\\n

    macos-option-as-alt = right
    """
    #expect(parsed(config) == [
        "keybind = shift+enter=text:\\n",
        "macos-option-as-alt = right",
        "keybind = shift+tab=csi:Z",
    ])
}

@Test func keyboardConfigKeepsCsiAndEscKeybinds() {
    let config = """
    keybind = f1=csi:11~
    keybind = alt+left=esc:b
    keybind = home=scroll_to_top
    """
    #expect(parsed(config) == [
        "keybind = f1=csi:11~",
        "keybind = alt+left=esc:b",
        "keybind = shift+tab=csi:Z",
        "macos-option-as-alt = true",
    ])
}
