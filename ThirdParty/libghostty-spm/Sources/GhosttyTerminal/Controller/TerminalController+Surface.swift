//
//  TerminalController+Surface.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

extension TerminalController {
    /// Creates a new Ghostty surface with the given configuration.
    ///
    /// The `platformSetup` closure lets the caller fill in
    /// platform-specific fields (`platform_tag`, `platform`, `scale_factor`)
    /// on the raw surface config struct before the surface is created.
    func createSurface(
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let app else { return nil }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.context = configuration.context.ghosttyValue
        configureBackend(&surfaceConfig, from: configuration)

        if let fontSize = configuration.fontSize {
            surfaceConfig.font_size = fontSize
        }

        return finalizeSurface(
            app: app,
            bridge: bridge,
            configuration: configuration,
            config: &surfaceConfig,
            workingDirectory: configuration.workingDirectory,
            platformSetup: platformSetup
        )
    }

    func retain(_ bridge: TerminalCallbackBridge) {
        retainedBridges.append(bridge)
    }

    func remove(_ bridge: TerminalCallbackBridge) {
        retainedBridges.removeAll { $0 === bridge }
    }

    var retainedBridgeCount: Int {
        retainedBridges.count
    }

    private func configureBackend(
        _ config: inout ghostty_surface_config_s,
        from options: TerminalSurfaceOptions
    ) {
        guard case let .inMemory(session) = options.backend else {
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_EXEC
            return
        }

        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = Unmanaged.passUnretained(session).toOpaque()
        config.receive_buffer = InMemoryTerminalSession.receiveBufferCallback
        config.receive_resize = InMemoryTerminalSession.receiveResizeCallback
    }

    private func finalizeSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        workingDirectory: String?,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        // strdup arena: every C string we hand to ghostty_surface_config_s
        // (working_directory, command, env keys/values) must stay alive until
        // ghostty_surface_new returns. `defer` frees them after buildSurface.
        var allocations: [UnsafeMutablePointer<CChar>] = []
        func cstr(_ string: String) -> UnsafePointer<CChar> {
            let pointer = strdup(string)!
            allocations.append(pointer)
            return UnsafePointer(pointer)
        }
        defer { allocations.forEach { free($0) } }

        if let workingDirectory {
            config.working_directory = cstr(workingDirectory)
        }
        if let command = configuration.execCommand, !command.isEmpty {
            config.command = cstr(command)
        }

        var envVars: [ghostty_env_var_s] = configuration.execEnvironment.map { key, value in
            ghostty_env_var_s(key: cstr(key), value: cstr(value))
        }
        return envVars.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress, !buffer.isEmpty {
                config.env_vars = base
                config.env_var_count = buffer.count
            }
            return buildSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &config,
                platformSetup: platformSetup
            )
        }
    }

    private func buildSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        platformSetup(&config)
        guard let surface = ghostty_surface_new(app, &config) else {
            return nil
        }

        retain(bridge)

        if case let .inMemory(session) = configuration.backend {
            session.setSurface(surface)
        }

        return surface
    }
}
