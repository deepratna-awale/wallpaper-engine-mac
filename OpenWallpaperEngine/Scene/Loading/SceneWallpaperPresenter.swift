import MetalKit

/// One display's view of a shared scene (`SceneWallpaperInstance`): it holds the instance while the
/// display shows it and hands the instance the view's draws. Everything else (loading, scripts,
/// particles, sound) belongs to the instance.
final class SceneWallpaperPresenter: NSObject, MTKViewDelegate {
    typealias Lease = WallpaperInstanceLease<WallpaperInstanceKey, SceneWallpaperInstance>

    private var lease: Lease?

    var instance: SceneWallpaperInstance? { lease?.instance }

    /// Shows `lease`'s instance in `view`.
    @MainActor
    func show(_ lease: Lease, in view: MTKView) {
        self.lease = lease
        lease.instance.attach(self, view: view)
    }

    /// Stops showing the instance; it stops too once no display shows it.
    @MainActor
    func stop() {
        guard let lease else { return }
        lease.instance.detach(self)
        lease.release()
        self.lease = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // MTKView draws on the main thread.
        MainActor.assumeIsolated { lease?.instance.draw(self, in: view) }
    }
}
