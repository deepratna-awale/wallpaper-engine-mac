import simd

/// Flattens a particle object's system and its `children`, depth first, into the scene's list
/// of particle systems: each child follows its parent and names it by index
/// (`ParticleChildLink.parentIndex`).
struct ParticleFamilyBuilder {
    /// Reads a particle json; nil when it can't be read (the reader logs why).
    let load: (String) -> WEParticleSystem?
    /// Builds one system of the family from its json, emitter transform and instance overrides;
    /// nil when it can't draw (no material or texture).
    let build: (_ path: String, _ system: WEParticleSystem, _ world: SceneAffineTransform,
                _ overrides: SceneParticleOverrides) -> SceneMetalParticleSystem?
    /// Where a failure is reported, with the object it belongs to.
    let report: (String) -> Void

    /// The family of the system at `path`, the root first. `world` is the root emitter's authored
    /// world transform.
    func family(_ path: String, world: SceneAffineTransform,
                overrides: SceneParticleOverrides) -> [SceneMetalParticleSystem] {
        var family: [SceneMetalParticleSystem] = []
        append(path, link: nil, world: world, overrides: overrides, ancestors: [], into: &family)
        return family
    }

    private func append(_ path: String, link: ParticleChildLink?, world: SceneAffineTransform,
                        overrides: SceneParticleOverrides, ancestors: [String],
                        into family: inout [SceneMetalParticleSystem]) {
        guard let json = load(path) else {
            if link != nil { report("child particle system \(path) can't be read") }
            return
        }
        guard var system = build(path, json, world, overrides) else {
            if link != nil { report("child particle system \(path) has no drawable material") }
            return
        }
        let children = json.children ?? []
        if link?.instanced == true, json.renderer?.first?.name == "rope" {
            report("\(path) draws a rope through the particles of all its instances, not one per instance")
        }
        system.link = link
        system.hasEventChildren = children.contains { Self.kind($0) != .static }
        let index = family.count
        family.append(system)
        for child in children {
            guard let name = child.name, !name.isEmpty else { continue }
            guard !ancestors.contains(name), name != path else {
                report("particle system \(path) lists its own ancestor \(name) as a child; skipped")
                continue
            }
            guard let kind = Self.kind(child) else {
                report("particle child \(name) has an unknown type \(child.type ?? ""); skipped")
                continue
            }
            if ((child.flags ?? 0) & 1) != 0 {
                report("child \(name) takes its control points from \(path)'s particles, which isn't supported; it keeps its own")
            }
            let childLink = Self.link(child, kind: kind, parentIndex: index, parent: link)
            // Bit 1: the child keeps its own colours (WE's "disable color overrides on child particles").
            var childOverrides = overrides
            if ((child.flags ?? 0) & 2) != 0 {
                childOverrides.tint = SIMD3(repeating: 1)
                childOverrides.brightness = 1
            }
            append(name, link: childLink, world: childLink.emitter(parent: world), overrides: childOverrides,
                   ancestors: ancestors + [path], into: &family)
        }
    }

    /// A child's type; `static` when it has none.
    static func kind(_ child: WEParticleChild) -> ParticleChildLink.Kind? {
        switch child.type?.lowercased() {
        case nil, "", "static": return .static
        case "eventfollow": return .follow
        case "eventspawn": return .spawn
        case "eventdeath": return .death
        default: return nil
        }
    }

    static func link(_ child: WEParticleChild, kind: ParticleChildLink.Kind, parentIndex: Int,
                     parent: ParticleChildLink?) -> ParticleChildLink {
        let origin = child.origin?.vectorValue ?? (0, 0, 0)
        let scale = child.scale?.vectorValue ?? (1, 1, 1)
        let angles = child.angles?.vectorValue ?? (0, 0, 0)
        let local = SceneLocalTransform(origin: SIMD2(Float(origin.0), Float(origin.1)),
                                        scale: SIMD2(Float(scale.0), Float(scale.1)), angle: Float(angles.2))
        let parentInstanced = parent?.instanced == true
        let instances: Int
        if kind != .static {
            instances = max(child.maxcount ?? 10, 0)
        } else {
            instances = parentInstanced ? parent?.maximumInstances ?? 1 : 1
        }
        return ParticleChildLink(parentIndex: parentIndex, kind: kind, local: local,
                                 probability: Float(child.probability ?? 1), maximumInstances: instances,
                                 instanced: kind != .static || parentInstanced)
    }
}
