import Foundation

/// App Group 里一份「租约」文件，给 App、卡片、控件三个进程当互斥锁用。
///
/// 为什么需要它：refreshToken 每换发一次，旧的立刻作废。三个进程各自续期，
/// 两个进程同时发起时，后到服务端的那个必然拿作废的 refreshToken 被拒——
/// 再被判成「登录态失效」，把另一个进程刚换来的有效凭证连带整个会话一起清掉。
/// `authRevision` 只能让「已经写回」的换发被看见，正在进行中的窗口只有锁能关上。
///
/// 为什么不用 `flock`：iOS 挂起一个进程时，只要它还占着 App Group 共享容器里的
/// 文件锁，就直接 SIGKILL，终止码写成 `0xdead10cc`。而续期全程持锁等网络回来
/// （`timeoutIntervalForResource` 40 秒），这段时间用户随手把 App 划走就必杀——
/// TestFlight 上 8/15–8/17 那四份崩溃全是这一个。租约是一份普通文件，
/// 系统不把它当锁，不受这条规矩管。
///
/// 互斥靠 `O_CREAT | O_EXCL` 的原子创建：文件在就是有人持着，建成了就是拿到了。
/// 持有者进程猝死会留下租约文件没人删，所以文件里写了到期时间，过期的那份
/// 由下一个来抢的人清掉——`leaseDuration` 就是「持有者最久能占多久」。
///
/// 拿锁是非阻塞轮询 + `Task.sleep`，不占线程。拿不到（等满超时）返回 nil，
/// 调用方降级为不加锁继续——最坏退回没有锁的现状，不会把续期堵死。
struct CrossProcessLock: Sendable {
    /// 一次成功的持锁。释放靠 `release()`；忘了释放的话，租约到期后会被别人抢走。
    struct Holding: Sendable {
        fileprivate let path: String
        fileprivate let owner: String

        /// 只删自己那份：这次持有要是已经超时被别人抢走了，直接删就把别人的锁删了。
        func release() {
            guard Lease.read(at: path)?.owner == owner else { return }
            unlink(path)
        }
    }

    private let path: String?
    private let leaseDuration: TimeInterval

    /// - Parameter leaseDuration: 租约有效期，必须长过持有者最久的那次持锁
    ///   （续期是 40 秒资源超时 + 钥匙串写回），否则人还在跑锁就被抢了。
    ///   代价是持有者猝死后，这么久之内别人抢不到——只会降级成不加锁，不会卡死。
    init(name: String, leaseDuration: TimeInterval = 90) {
        path = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SnapshotStore.appGroup)?
            .appendingPathComponent(name).path
        self.leaseDuration = leaseDuration
    }

    /// 轮询到拿到为止，最多等 `timeout` 秒。容器开不出来也返回 nil。
    func acquire(timeout: TimeInterval = 25, pollInterval: Duration = .milliseconds(100)) async -> Holding? {
        guard let path else { return nil }
        // 每次持有换一个新 id：`release()` 只认自己这一次，认不出上一次留下的租约。
        let owner = UUID().uuidString
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if create(at: path, owner: owner) {
                return Holding(path: path, owner: owner)
            }
            // 文件已经在了。过期的可以抢，没过期的只能等。
            if isStale(at: path), await takeOver(at: path, owner: owner, settle: pollInterval) {
                return Holding(path: path, owner: owner)
            }
            guard Date.now < deadline else { return nil }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// 这份租约能不能抢。
    private func isStale(at path: String) -> Bool {
        if let lease = Lease.read(at: path) { return lease.isExpired }
        // 读不出一份完整租约,只有两种可能:有人刚 `O_EXCL` 建出文件还没写完
        // (那 mtime 就是此刻),或者这是旧版 `flock` 留下的空文件、写坏的半份
        // (mtime 早就过去了)。拿 mtime 兜底,新的等下一轮,旧的直接抢走——
        // 不兜的话,从 flock 版本升上来的用户会被那个空文件永远挡住,
        // 这把锁再也拿不到,等于白装。
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate] as? Date else { return false }
        return Date.now.timeIntervalSince(modified) > leaseDuration
    }

    /// 没人持有时把租约建出来。`O_EXCL` 保证只会有一个进程建成功。
    private func create(at path: String, owner: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { return false }
        let written = lease(for: owner).writeTo(descriptor)
        close(descriptor)
        // 建出来了却没写进去，留着就是一份谁也读不懂的租约，白堵到过期为止。
        if !written { unlink(path) }
        return written
    }

    /// 抢过期租约：写一份新的到临时文件，再 `rename` 原子覆盖上去。
    ///
    /// 两个进程可能同时判定同一份租约过期、同时覆盖，所以覆盖完等一小会儿再回读，
    /// 后写的那个才算数，读到不是自己的就让开继续轮询。这一手不是严格互斥——
    /// 两次覆盖挨得极近时有可能都认为自己赢了，代价是退回「两个进程同时续期」，
    /// 也就是这把锁本来要挡的那个旧问题，不会更糟；而它只在有进程猝死、
    /// 且租约刚好过期的那一瞬间才走得到。
    private func takeOver(at path: String, owner: String, settle: Duration) async -> Bool {
        let temporary = path + ".takeover-" + owner
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { return false }
        let written = lease(for: owner).writeTo(descriptor)
        close(descriptor)
        guard written, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        try? await Task.sleep(for: settle)
        return Lease.read(at: path)?.owner == owner
    }

    private func lease(for owner: String) -> Lease {
        Lease(owner: owner, expiresAt: Date.now.addingTimeInterval(leaseDuration))
    }

    /// 租约文件的内容：一行 owner，一行到期时间（Unix 秒）。
    private struct Lease {
        let owner: String
        let expiresAt: Date

        var isExpired: Bool { expiresAt <= .now }

        /// 读不出来、只有半行、时间戳解析不了，一律返回 nil——那多半是有人刚
        /// `O_EXCL` 建出文件还没来得及写。当成过期抢走的话，就把人家正用着的锁抢了，
        /// 所以这里宁可多等一轮。
        static func read(at path: String) -> Lease? {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let parts = text.split(separator: "\n", maxSplits: 1)
            guard parts.count == 2, let seconds = TimeInterval(parts[1]) else { return nil }
            return Lease(owner: String(parts[0]), expiresAt: Date(timeIntervalSince1970: seconds))
        }

        func writeTo(_ descriptor: Int32) -> Bool {
            let bytes = Array("\(owner)\n\(expiresAt.timeIntervalSince1970)".utf8)
            return bytes.withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress, buffer.count) == buffer.count
            }
        }
    }
}
