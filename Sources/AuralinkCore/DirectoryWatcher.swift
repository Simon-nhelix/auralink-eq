import Foundation
import Darwin

/// Watches a directory's contents and reconnects when its path is replaced.
/// Missing directories are observed through their nearest existing ancestor;
/// watching never creates the user's collection or its parent directories.
public final class DirectoryWatcher {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Binding {
        let identity: Identity
        let token: UUID
        let source: DispatchSourceFileSystemObject
    }

    private let url: URL
    private let queue = DispatchQueue(label: "com.auralink.eq.directory-watch")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let onChange: @Sendable () -> Void
    // Accessed only on queue, including cancellation and deinitialization.
    private var bindings: [String: Binding] = [:]
    private var retryTimer: DispatchSourceTimer?
    private var targetIdentity: Identity?
    private var cancelled = false

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
        queue.sync { _ = reconcile() }
    }

    public func cancel() {
        let stop = {
            self.cancelled = true
            self.retryTimer?.cancel()
            self.retryTimer = nil
            for binding in self.bindings.values { binding.source.cancel() }
            self.bindings.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stop()
        } else {
            queue.sync(execute: stop)
        }
    }

    deinit { cancel() }

    private static func identity(at path: String) -> Identity? {
        var info = stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// Returns whether the target directory appeared, disappeared, or changed inode.
    private func reconcile() -> Bool {
        guard !cancelled else { return false }
        let nextIdentity = Self.identity(at: url.path)
        let changed = targetIdentity != nextIdentity
        targetIdentity = nextIdentity

        var desired: [String: Identity] = [:]
        if let nextIdentity { desired[url.path] = nextIdentity }
        var ancestor = url.deletingLastPathComponent()
        while true {
            if let identity = Self.identity(at: ancestor.path) {
                desired[ancestor.path] = identity
                break
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }

        for (path, binding) in bindings where desired[path] != binding.identity {
            binding.source.cancel()
            bindings.removeValue(forKey: path)
        }
        for (path, identity) in desired where bindings[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            var info = stat()
            guard fstat(fd, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  Identity(device: info.st_dev, inode: info.st_ino) == identity else {
                close(fd)
                continue
            }
            let token = UUID()
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.handleEvent(path: path, token: token) }
            source.setCancelHandler { close(fd) }
            bindings[path] = Binding(identity: identity, token: token, source: source)
            source.resume()
        }

        // Covers creation/open races and temporary permission failures. Once
        // attached to an existing target, normal observation is event driven.
        let needsRetry = nextIdentity == nil || bindings.count != desired.count
        if needsRetry && retryTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.reconcile() { self.onChange() }
            }
            retryTimer = timer
            timer.resume()
        } else if !needsRetry {
            retryTimer?.cancel()
            retryTimer = nil
        }
        return changed
    }

    private func handleEvent(path: String, token: UUID) {
        guard !cancelled, let binding = bindings[path], binding.token == token else { return }
        if !binding.source.data.intersection([.delete, .rename, .revoke]).isEmpty {
            binding.source.cancel()
            bindings.removeValue(forKey: path)
        }
        let changed = reconcile()
        if changed || path == url.path { onChange() }
    }
}
