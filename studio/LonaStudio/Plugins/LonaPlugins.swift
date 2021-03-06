//
//  LonaPlugins.swift
//  LonaStudio
//
//  Created by devin_abbott on 5/4/18.
//  Copyright © 2018 Devin Abbott. All rights reserved.
//

import Foundation
import AppKit

enum LonaPluginActivationEvent: String, Decodable {
    case onSaveComponent = "onSave:component"
    case onSaveColors = "onSave:colors"
    case onSaveTextStyles = "onSave:textStyles"
    case onReloadWorkspace = "onReload:workspace"
    case onChangeTheme = "onChange:theme"
    case onChangeFileSystemComponents = "onChange:fileSystem:components"
}

struct LonaPluginConfig: Decodable {
    var main: String
    var activationEvents: [LonaPluginActivationEvent]?
    var command: String?
}

class LonaPlugins {
    typealias SubscriptionHandle = () -> Void

    class Handler {
        var callback: () -> Void

        init(callback: @escaping () -> Void) {
            self.callback = callback
        }
    }

    struct PluginFile {

        // MARK: Public

        let url: URL

        var name: String {
            return url.lastPathComponent
        }

        func run() {
            guard let config = config else { return }

            var arguments: [String] = []

            if let command = config.command {
                arguments.append(url.appendingPathComponent(command).path)
            }

            if LonaPlugins.nodeDebuggerIsEnabled {
                arguments.append("--inspect-brk")
            }

            arguments.append(url.appendingPathComponent(config.main).path)

            let process = LonaNode.makeProcess(
                arguments: arguments,
                currentDirectoryPath: url.path
            )

            let rpcService = RPCService()

            process.execute(
                sync: false,
                onLaunch: ({ _ in
                    if let inputPipe = process.standardInput as? Pipe {
                        rpcService.sendData = inputPipe.fileHandleForWriting.write
                    }
                    process.pipeFromStandardOutput(onData: { data in
                        let packets = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
                        packets.forEach(rpcService.handleData)
                    })
                })
            )
        }

        // MARK: Private

        var config: LonaPluginConfig? {
            let configUrl = url.appendingPathComponent("lonaplugin.json", isDirectory: false)
            guard let contents = try? Data(contentsOf: configUrl) else { return nil }
            return try? JSONDecoder().decode(LonaPluginConfig.self, from: contents)
        }
    }

    let urls: [URL]

    private static var handlers: [LonaPluginActivationEvent: [Handler]] = [:]

    init(urls: [URL]) {
        self.urls = urls
    }

    func pluginFiles() -> [PluginFile] {
        return urls.flatMap { LonaPlugins.pluginFiles(in: $0) }
    }

    func pluginFile(named name: String) -> PluginFile? {
        return pluginFiles().first(where: { arg in arg.name == name })
    }

    func pluginFilesActivatingOn(eventType: LonaPluginActivationEvent) -> [PluginFile] {
        return pluginFiles().filter({ file in
            file.config?.activationEvents?.contains(eventType) ?? false
        })
    }

    func register(eventType: LonaPluginActivationEvent, handler callback: @escaping () -> Void) -> SubscriptionHandle {
        let handler = Handler(callback: callback)

        var handlerList = LonaPlugins.handlers[eventType] ?? []
        handlerList.append(handler)
        LonaPlugins.handlers[eventType] = handlerList

        return {
            let handlerList = LonaPlugins.handlers[eventType] ?? []
            LonaPlugins.handlers[eventType] = handlerList.filter({ $0 !== handler })
        }
    }

    func register(eventTypes: [LonaPluginActivationEvent], handler callback: @escaping () -> Void) -> SubscriptionHandle {
        let subscriptions = eventTypes.map({ register(eventType: $0, handler: callback) })
        return {
            subscriptions.forEach({ sub in sub() })
        }
    }

    func trigger(eventType: LonaPluginActivationEvent) {
        LonaPlugins.current.pluginFilesActivatingOn(eventType: eventType).forEach({ $0.run() })

        LonaPlugins.handlers[eventType]?.forEach({ $0.callback() })
    }

    // MARK: - STATIC

    // this is the list of the plugins in:
    // - the `/plugins` folder of the current workspace
    // - the `~/Library/Application Support/${BUNDLE_IDENFIFIER}/plugins` folder
    static var current: LonaPlugins {
        do {
            let applicationSupportFolderURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as! String
            let commonPluginsfolder = applicationSupportFolderURL.appendingPathComponent("\(appName)/plugins", isDirectory: true)
            if !FileManager.default.fileExists(atPath: commonPluginsfolder.path) {
                try FileManager.default.createDirectory(at: commonPluginsfolder, withIntermediateDirectories: true, attributes: nil)
            }

            return LonaPlugins(urls: [
                commonPluginsfolder,
                CSUserPreferences.workspaceURL.appendingPathComponent("plugins", isDirectory: true)
            ])
        } catch {
            print(error)
            return LonaPlugins(urls: [
                CSUserPreferences.workspaceURL.appendingPathComponent("plugins", isDirectory: true)
            ])
        }
    }

    static func pluginFiles(in workspace: URL) -> [PluginFile] {
        var files: [PluginFile] = []

        let fileManager = FileManager.default
        let keys = [URLResourceKey.isSymbolicLinkKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsHiddenFiles]
        let ignoreList = [".git", "node_modules"]

        var stack: [URL] = [workspace]
        var visited: [URL] = []

        while let url = stack.popLast() {
            visited.append(url)

            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: {(_, _) -> Bool in true }) else { continue }

            outer: while let file = enumerator.nextObject() as? URL {
                for ignore in ignoreList where file.path.contains(ignore) {
                    enumerator.skipDescendants()
                    continue outer
                }

                let isSymlink = ((try? file.resourceValues(forKeys: [URLResourceKey.isSymbolicLinkKey]).isSymbolicLink) as Bool??)

                if isSymlink == true, !visited.contains(file) {
                    stack.append(file.resolvingSymlinksInPath())
                }

                if file.lastPathComponent == "lonaplugin.json" {
                    files.append(PluginFile(url: file.deletingLastPathComponent()))
                }
            }
        }

        return files
    }

    private static var nodeDebuggerIsEnabledKey = "Node debugger enabled"

    static var nodeDebuggerIsEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: nodeDebuggerIsEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: nodeDebuggerIsEnabledKey)
        }
    }
}
