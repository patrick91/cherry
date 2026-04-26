//
//  TerminalInputBarKey.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    enum TerminalInputBarKey {
        case esc
        case tab
        case arrowLeft
        case arrowUp
        case arrowDown
        case arrowRight
        case symbol(String)
        case paste
    }
#endif
