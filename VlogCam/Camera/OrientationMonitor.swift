import CoreMotion
import Foundation

/// 加速度センサーで端末の物理的な向きを判定する。
/// 画面は縦固定・コントロールセンターの回転ロック中でも向きを取得できる。
final class OrientationMonitor: @unchecked Sendable {
    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var _current: DeviceOrientation = .portrait

    var current: DeviceOrientation {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        queue.maxConcurrentOperationCount = 1
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let x = a.x
            let y = a.y
            // ほぼ水平に置かれている時や、斜めで判断がつかない時は直前の向きを維持
            guard max(abs(x), abs(y)) > 0.5, abs(abs(x) - abs(y)) > 0.25 else { return }

            let next: DeviceOrientation
            if abs(y) > abs(x) {
                next = y < 0 ? .portrait : .portraitUpsideDown
            } else {
                next = x < 0 ? .landscapeLeft : .landscapeRight
            }
            self.lock.lock()
            self._current = next
            self.lock.unlock()
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
