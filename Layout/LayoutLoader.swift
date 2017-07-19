//  Copyright © 2017 Schibsted. All rights reserved.

import Foundation

typealias LayoutLoaderCallback = (LayoutNode?, LayoutError?) -> Void

// Cache for previously loaded layouts
private var cache = [URL: Layout]()
private let queue = DispatchQueue(label: "com.Layout")

// API for loading a layout XML file
class LayoutLoader {
    private var _xmlURL: URL!
    private var _projectDirectory: URL?
    private var _dataTask: URLSessionDataTask?
    private var _state: Any = ()
    private var _constants: [String: Any] = [:]
    private var _strings: [String: String]?

    // MARK: LayoutNode loading

    public func loadLayoutNode(
        named: String,
        bundle: Bundle = Bundle.main,
        relativeTo: String = #file,
        state: Any = (),
        constants: [String: Any] = [:]
    ) throws -> LayoutNode {
        _state = state
        _constants = constants

        let layout = try loadLayout(
            named: named,
            bundle: bundle,
            relativeTo: relativeTo
        )
        return try LayoutNode(
            layout: layout,
            state: state,
            constants: constants
        )
    }

    public func loadLayoutNode(
        withContentsOfURL xmlURL: URL,
        relativeTo: String? = #file,
        state: Any = (),
        constants: [String: Any] = [:],
        completion: @escaping LayoutLoaderCallback
    ) {
        _state = state
        _constants = constants

        loadLayout(
            withContentsOfURL: xmlURL,
            relativeTo: relativeTo,
            completion: { [weak self] layout, error in
                self?._state = state
                self?._constants = constants
                do {
                    guard let layout = layout else {
                        if let error = error {
                            throw error
                        }
                        return
                    }
                    try completion(LayoutNode(
                        layout: layout,
                        state: state,
                        constants: constants
                    ), nil)
                } catch {
                    completion(nil, LayoutError(error))
                }
            }
        )
    }

    public func reloadLayoutNode(withCompletion completion: @escaping LayoutLoaderCallback) {
        queue.sync { cache.removeAll() }
        guard let xmlURL = _xmlURL, _dataTask == nil else {
            completion(nil, nil)
            return
        }
        loadLayoutNode(
            withContentsOfURL: xmlURL,
            relativeTo: nil,
            state: _state,
            constants: _constants,
            completion: completion
        )
    }

    // MARK: Layout loading

    public func loadLayout(
        named: String,
        bundle: Bundle = Bundle.main,
        relativeTo: String = #file
    ) throws -> Layout {
        assert(Thread.isMainThread)
        guard let xmlURL = bundle.url(forResource: named, withExtension: nil) ??
            bundle.url(forResource: named, withExtension: "xml") else {
                throw LayoutError.message("No layout XML file found for `\(named)`")
        }
        var _layout: Layout?
        var _error: Error?
        loadLayout(
            withContentsOfURL: xmlURL,
            relativeTo: relativeTo
        ) { layout, error in
            _layout = layout
            _error = error
        }
        if let error = _error {
            throw error
        }
        return _layout!
    }

    public func loadLayout(
        withContentsOfURL xmlURL: URL,
        relativeTo: String? = #file,
        completion: @escaping (Layout?, LayoutError?) -> Void
    ) {
        _dataTask?.cancel()
        _dataTask = nil
        _xmlURL = xmlURL
        _strings = nil

        // If it's a bundle resource url, replacw with equivalent source url
        if xmlURL.isFileURL {
            let bundlePath = Bundle.main.bundleURL.absoluteString
            if xmlURL.absoluteString.hasPrefix(bundlePath) {
                if _projectDirectory == nil, let relativeTo = relativeTo,
                    let projectDirectory = findProjectDirectory(at: "\(relativeTo)") {
                    _projectDirectory = projectDirectory
                }
                if let projectDirectory = _projectDirectory {
                    var parts = xmlURL.absoluteString
                        .substring(from: bundlePath.endIndex).components(separatedBy: "/")
                    for (i, part) in parts.enumerated().reversed() {
                        if part.hasSuffix(".bundle") {
                            parts.removeFirst(i + 1)
                            break
                        }
                    }
                    let path = parts.joined(separator: "/")
                    do {
                        if let url = try findSourceURL(forRelativePath: path, in: projectDirectory) {
                            _xmlURL = url
                        }
                    } catch {
                        completion(nil, LayoutError(error))
                        return
                    }
                }
            }
        }

        // Check cache
        var layout: Layout?
        queue.sync { layout = cache[_xmlURL] }
        if let layout = layout {
            completion(layout, nil)
            return
        }

        // Load synchronously if it's a local file and we're on the main thread already
        if _xmlURL.isFileURL, Thread.isMainThread {
            do {
                let data = try Data(contentsOf: _xmlURL)
                let layout = try Layout(xmlData: data, relativeTo: relativeTo ?? _xmlURL.path)
                queue.async { cache[self._xmlURL] = layout }
                completion(layout, nil)
            } catch let error {
                completion(nil, LayoutError(error))
            }
            return
        }

        // Load asynchronously
        let xmlURL = _xmlURL!
        _dataTask = URLSession.shared.dataTask(with: xmlURL) { data, _, error in
            DispatchQueue.main.async {
                self._dataTask = nil
                if self._xmlURL != xmlURL {
                    return // Must have been cancelled
                }
                do {
                    guard let data = data else {
                        if let error = error {
                            throw error
                        }
                        return
                    }
                    let layout = try Layout(xmlData: data, relativeTo: relativeTo)
                    queue.async { cache[self._xmlURL] = layout }
                    completion(layout, nil)
                } catch let error {
                    completion(nil, LayoutError(error))
                }
            }
        }
        _dataTask?.resume()
    }

    // MARK: String loading

    public func loadLocalizedStrings() throws -> [String: String] {
        if let strings = _strings {
            return strings
        }
        var path = "Localizable.strings"
        let localizedPath = Bundle.main.path(forResource: "Localizable", ofType: "strings")
        if let resourcePath = Bundle.main.resourcePath, let localizedPath = localizedPath {
            path = localizedPath.substring(from: resourcePath.endIndex)
        }
        if let projectDirectory = _projectDirectory,
            let url = try findSourceURL(forRelativePath: path, in: projectDirectory) {
            _strings = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            return _strings!
        }
        if let stringsFile = localizedPath {
            _strings = NSDictionary(contentsOfFile: stringsFile) as? [String: String] ?? [:]
            return _strings!
        }
        return [:]
    }

    public func setSourceURL(_ sourceURL: URL, for path: String) {
        _setSourceURL(sourceURL, for: path)
    }
}

#if arch(i386) || arch(x86_64)

    // MARK: Only applicable when running in the simulator

    private var _projectDirectory: URL?
    private var _sourceURLCache = [String: URL]()

    private func findProjectDirectory(at path: String) -> URL? {
        if let projectDirectory = _projectDirectory, path.hasPrefix(projectDirectory.path) {
            return projectDirectory
        }
        var url = URL(fileURLWithPath: path)
        if !url.pathExtension.isEmpty {
            url = url.deletingLastPathComponent()
        }
        if url.lastPathComponent.isEmpty {
            return nil
        }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return nil
        }
        let parent = url.deletingLastPathComponent()
        for file in files {
            let pathExtension = URL(fileURLWithPath: file).pathExtension
            if pathExtension == "xcodeproj" || pathExtension == "xcworkspace" {
                if let url = findProjectDirectory(at: parent.path) {
                    return url
                }
                _projectDirectory = url
                return url
            }
        }
        return findProjectDirectory(at: parent.path)
    }

    private func findSourceURL(forRelativePath path: String, in directory: URL, usingCache: Bool = true) throws -> URL? {
        if let url = _sourceURLCache[path], FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        var parts = URL(fileURLWithPath: path).pathComponents
        if parts[0] == "/" {
            parts.removeFirst()
        }
        var results = [URL]()
        for file in files where !file.hasSuffix(".build") && !file.hasSuffix(".app") {
            let directory = directory.appendingPathComponent(file)
            if file == parts[0] {
                if parts.count == 1 {
                    results.append(directory) // Not actually a directory
                    continue
                }
                try findSourceURL(
                    forRelativePath: parts.dropFirst().joined(separator: "/"),
                    in: directory,
                    usingCache: false
                ).map {
                    results.append($0)
                }
            }
            try findSourceURL(
                forRelativePath: path,
                in: directory,
                usingCache: false
            ).map {
                results.append($0)
            }
        }
        guard results.count <= 1 else {
            throw LayoutError.multipleMatches(results, for: path)
        }
        if usingCache {
            guard let url = results.first else {
                throw LayoutError.message("Unable to locate source file for \(path)")
            }
            _sourceURLCache[path] = url
        }
        return results.first
    }

    private func _setSourceURL(_ sourceURL: URL, for path: String) {
        _sourceURLCache[path] = sourceURL
    }

#else

    private func findProjectDirectory(at _: String) -> URL? { return nil }
    private func findSourceURL(forRelativePath _: String, in _: URL) throws -> URL? { return nil }
    private func _setSourceURL(_: URL, for _: String) {}

#endif
