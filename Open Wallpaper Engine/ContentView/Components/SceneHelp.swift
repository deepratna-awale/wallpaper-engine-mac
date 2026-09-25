import SwiftUI

/// An ⓘ that reads as clickable and behaves that way: click for a selectable popover, hover for
/// the standard tooltip.
struct InfoTip: View {
    private let text: String
    @State private var isPresented = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(isPresented ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

/// Tooltip copy for effects, shaders and their parameters.
///
/// Wallpaper Engine ships no descriptions for authored parameters — a control is often just a
/// shader constant name — so the guidance here is written to say what a value actually does and
/// which direction to move it.
enum SceneHelp {
    // MARK: - Effects

    private static let effectDescriptions: [String: String] = [
        "audiobars": "Draws bars that rise and fall with the audio you are hearing. Needs Screen & System Audio Recording permission.",
        "blend": "Mixes a second image into the layer using a Photoshop-style blend mode.",
        "blendgradient": "Fades the layer into a gradient, usually to darken edges or tint one side.",
        "blur": "Softens the layer. This is the cheap blur; use Blur Precise when you need a cleaner result.",
        "blurprecise": "A higher quality, more expensive blur. Prefer it for large radii where the fast blur shows banding.",
        "blurradial": "Blurs outward from a centre point, giving a zoom or speed streak look.",
        "chromaticaberration": "Splits red and blue channels apart, imitating a cheap camera lens. Subtle values read best.",
        "cloudmotion": "Drifts a cloud texture across the layer.",
        "clouds": "Overlays procedural clouds.",
        "colorkey": "Makes one colour transparent, like a green screen. Raise Tolerance until the colour disappears, then raise Fuzziness to soften the edge.",
        "cursorripple": "Sends ripples out from the pointer as it moves.",
        "depthparallax": "Shifts parts of the image by a depth map so it looks three-dimensional as the pointer moves.",
        "edgedetection": "Keeps only the outlines in the image.",
        "empty": "A placeholder that does nothing. Authors use it to reserve a slot in the effect stack.",
        "filmgrain": "Adds moving film grain. Keep the amount low or it swamps darker scenes.",
        "fire": "Adds a rising flame distortion.",
        "fisheye": "Bulges the image outward from a centre point like a fisheye lens.",
        "foliagesway": "Sways the layer as if leaves were moving in wind.",
        "glitter": "Scatters sparkles across the layer.",
        "godrays": "Casts light shafts from a bright source through the scene.",
        "hueshift": "Rotates every colour around the colour wheel.",
        "hyperdrive": "Stretches the image into streaks for a warp-speed look.",
        "iris": "Opens or closes a circular mask over the layer.",
        "lightshafts": "Adds directional beams of light across the layer.",
        "localcontrast": "Sharpens local detail without changing overall brightness. High values look crunchy.",
        "motionblur": "Smears the image along its direction of motion.",
        "nitro": "Pulses a speed-boost distortion.",
        "opacity": "Fades the layer in or out.",
        "parallax": "Moves the layer against the pointer so it appears to sit at a different depth.",
        "perspective": "Tilts the layer in 3D space.",
        "pulse": "Scales the layer in time with the audio.",
        "reflection": "Mirrors the layer below itself, as if on water or glass.",
        "refraction": "Bends the image as if seen through rippled glass.",
        "scroll": "Slides the texture continuously, useful for tiling backgrounds.",
        "shake": "Jitters the layer. Masked so only part of the image moves.",
        "shimmer": "Runs a soft highlight across the layer.",
        "shine": "Sweeps a bright band across the layer. The mask controls which parts can catch the light.",
        "skew": "Leans the layer to one side.",
        "spin": "Rotates a circular region of the layer.",
        "swing": "Rocks the layer back and forth around its base.",
        "tint": "Multiplies the layer by a colour.",
        "transform": "Offsets, scales or rotates the layer.",
        "twirl": "Swirls the image around a centre point.",
        "vhs": "Adds tape distortion, colour bleed and scanlines.",
        "volumetricfog": "Adds depth-aware fog that thickens toward the bottom of the scene.",
        "watercaustics": "Projects rippling underwater light patterns.",
        "waterflow": "Pushes the image along as if it were flowing water.",
        "waterripple": "Adds expanding ripples across the surface.",
        "waterwaves": "Distorts the layer with rolling waves.",
        "xray": "Reveals a second image through a moving window."
    ]

    static func effect(_ name: String) -> String {
        effectDescriptions[name.lowercased()]
            ?? "Applies the \(name.lowercased()) effect to this layer."
    }

    // MARK: - Parameters

    /// Per-effect wording, because the same key means different things depending on the effect:
    /// `strength` is a pixel offset for Shake, a colour-split distance for Chromatic Aberration and
    /// an audio sensitivity for Audio Bars.
    private static let effectParameters: [String: [String: String]] = [
        "tint": [
            "alpha": "How strongly the tint colour is mixed in. 0 leaves the layer untouched, 1 replaces it with the colour."
        ],
        "opacity": [
            "alpha": "Transparency of the layer. 0 hides it completely, 1 is fully solid."
        ],
        "fisheye": [
            "size": "How much of the layer the lens covers. Small values bulge only the centre.",
            "scale": "How hard the lens bends the image. Negative values pinch inward instead of bulging out."
        ],
        "scroll": [
            "speedx": "Horizontal scroll speed. Negative scrolls left, 0 stops. Only looks seamless on tiling textures.",
            "speedy": "Vertical scroll speed. Negative scrolls up, 0 stops."
        ],
        "chromaticaberration": [
            "strength": "How far the red and blue channels separate. Keep it small — past a few pixels it stops reading as a lens and starts looking broken.",
            "centerfalloff": "How quickly the split fades toward the centre. High values keep the centre sharp and push the fringing to the edges, like a real lens."
        ],
        "colorkey": [
            "alpha": "Opacity left behind where the colour is keyed out. 0 makes matched pixels fully transparent.",
            "fuzziness": "Softness of the cut-out edge. Raise it if the keyed edge looks jagged; too high and the subject goes semi-transparent.",
            "tolerance": "How close a pixel must be to the key colour to be removed. Raise it until the background is gone, then stop — going further eats the subject."
        ],
        "spin": [
            "size": "Radius of the spinning disc, as a fraction of the layer.",
            "feather": "Softness of the disc edge. Very small values leave a visible hard circle."
        ],
        "depthparallax": [
            "depthx": "How far the image shifts horizontally with the pointer. Needs a depth map; without one nothing moves.",
            "depthy": "How far the image shifts vertically with the pointer.",
            "perspective": "Adds scaling with depth so near parts grow as they shift, rather than just sliding."
        ],
        "shake": [
            "strength": "How far the layer moves each shake, in pixels.",
            "speed": "How rapidly it shakes.",
            "friction": "How quickly each shake settles. High values give a short sharp jolt, low values keep it wobbling."
        ],
        "waterwaves": [
            "strength": "Height of the waves — how far pixels are displaced.",
            "speed": "How fast the waves travel.",
            "scale": "Wavelength. Low values give many small ripples, high values give a few broad swells.",
            "exponent": "Sharpness of the wave crests. 1 is a smooth sine; higher values give peaked, choppier water.",
            "direction": "Direction the waves travel, in degrees."
        ],
        "nitro": [
            "multiply": "Strength of the speed-boost distortion.",
            "smoothness": "How gradually the distortion ramps in and out. Low values snap, high values glide."
        ],
        "vhs": [
            "strength": "Overall amount of tape degradation.",
            "chromatic": "How far colour bleeds sideways, like worn tape.",
            "artifacts": "Density of dropouts and noise specks.",
            "distortionstrength": "How far the tracking glitch tears the image sideways.",
            "distortionspeed": "How often the tracking glitch rolls through.",
            "distortionwidth": "Height of the torn band. Small values give a thin tracking line, large values disturb most of the frame."
        ],
        "audiobars": [
            "opacity": "Transparency of the bars.",
            "strength": "How far the bars react to volume. Raise it for quiet music, lower it if the bars keep hitting the ceiling.",
            "minimum": "Height the bars keep in silence, so they do not vanish between beats.",
            "bars": "How many bars are drawn across the layer.",
            "gap": "Spacing between bars, as a fraction of their width.",
            "smoothing": "How much bar movement is averaged over time. High values glide, 0 reacts instantly and jitters.",
            "glow": "Brightness of the halo around each bar.",
            "red": "Red component of the bar colour.",
            "green": "Green component of the bar colour.",
            "blue": "Blue component of the bar colour."
        ],
        "hueshift": [
            "audioamount": "How far the hue rotates at full volume.",
            "audioexponent": "Shapes the response curve. Above 1 ignores quiet passages and reacts mainly to peaks.",
            "frequencymin": "Lowest frequency band that drives the shift. Raise it to ignore bass.",
            "frequencymax": "Highest frequency band that drives the shift. Lower it to ignore cymbals and hiss.",
            "intensity": "Hue rotation applied even without audio."
        ],
        "hyperdrive": [
            "audioamount": "How much the warp reacts to volume.",
            "audioexponent": "Shapes the response curve. Above 1 reacts mainly to peaks.",
            "frequencymin": "Lowest frequency band that drives the warp. Raise it to ignore bass.",
            "frequencymax": "Highest frequency band that drives the warp.",
            "strength": "How far the image stretches into streaks.",
            "speed": "How fast the streaks travel outward."
        ],
        "volumetricfog": [
            "density": "How thick the fog is. Small changes read strongly — start low.",
            "drift": "How fast the fog moves across the scene.",
            "near": "Depth where the fog starts. Nothing closer than this is fogged.",
            "far": "Depth where the fog reaches full density. Keep it above Fog Near or the gradient inverts."
        ],
        "parallax": [
            "amount": "How far the layer slides against the pointer. Give background layers more than foreground ones to sell the depth."
        ],
        "foliagesway": [
            "strength": "How far the leaves bend.",
            "scale": "Size of the sway pattern. Low values move the whole layer together, high values ripple through it.",
            "speeduv": "How fast the sway travels through the foliage."
        ],
        "waterripple": [
            "ripplestrength": "How far the surface is displaced by each ripple.",
            "scale": "Size of the ripples. Low values give broad swells, high values fine ridges.",
            "animationspeed": "How fast the ripples spread."
        ],
        "godrays": [
            "rayintensity": "Brightness of the shafts of light.",
            "raylength": "How far the shafts reach from their source.",
            "raythreshold": "How bright a pixel must be to emit rays. Lower it if nothing glows; raise it if the whole image smears."
        ],
        "lightshafts": [
            "colorwintensity": "Brightness of the shafts.",
            "rayradius": "How wide the shafts spread.",
            "rayspeed": "How fast the shafts drift."
        ]
    ]

    /// Fallback for authored shader constants, matched most-specific-first.
    private static let parameterDescriptions: [(match: String, text: String)] = [
        ("ray_threshold", "How bright a pixel must be before it casts rays. Lower it to catch more of the image, raise it to keep rays on highlights only."),
        ("ray_intensity", "Brightness of the light rays."),
        ("ray_length", "How far the rays reach from their source."),
        ("noise_amount", "How strongly noise distorts the result. Small values keep it organic; large values look grainy."),
        ("noise_scale", "Size of the noise pattern. Lower is coarser and blotchier, higher is finer."),
        ("blur_scale", "How far the blur reaches on each axis."),
        ("centerfalloff", "How quickly the effect fades away from the centre."),
        ("threshold", "The cut-off where the effect starts to apply. Lower catches more of the image, higher restricts it to the strongest pixels."),
        ("fuzziness", "Softness of the edge where the effect stops. Raise it to avoid a hard cut."),
        ("tolerance", "How closely a pixel must match before it is affected. Raise it until the whole target area is covered, then stop."),
        ("smoothness", "How gradually the effect blends at its boundary."),
        ("feather", "Softens the boundary of the affected region."),
        ("density", "How much of the area the effect fills."),
        ("friction", "How quickly the motion settles. High values stop it sharply, low values let it keep moving."),
        ("exponent", "Shapes the response curve. Above 1 emphasises peaks and ignores small values."),
        ("multiply", "Strength of the blend. 0 leaves the layer untouched, 1 applies it fully."),
        ("direction", "Direction the effect travels, in degrees."),
        ("angle", "Rotation applied by the effect, in degrees."),
        ("speedx", "Horizontal speed. Negative values move the other way, 0 stops."),
        ("speedy", "Vertical speed. Negative values move the other way, 0 stops."),
        ("repeatx", "How many times the texture tiles horizontally."),
        ("repeaty", "How many times the texture tiles vertically."),
        ("frequencymin", "Lowest audio frequency band that drives this. Raise it to ignore bass."),
        ("frequencymax", "Highest audio frequency band that drives this. Lower it to ignore hiss and cymbals."),
        ("audioamount", "How strongly audio drives this parameter."),
        ("audioexponent", "Shapes the audio response. Above 1 reacts mainly to peaks."),
        ("speed", "How quickly the effect animates. 0 freezes it."),
        ("frequency", "How often the pattern repeats over time."),
        ("phase", "Offsets the start of the animation, useful for de-syncing two copies of an effect."),
        ("center", "Point the effect radiates from, as a fraction of the layer (0.5, 0.5 is the middle)."),
        ("radius", "Size of the affected region."),
        ("bloomthreshold", "How bright a pixel must be before it glows."),
        ("bloom", "Strength of the glow around bright areas."),
        ("brightness", "Overall lightness. 1 leaves the layer unchanged."),
        ("contrast", "Separation between lights and darks. 1 leaves the layer unchanged."),
        ("saturation", "Colour richness. 0 is greyscale, 1 is unchanged."),
        ("exposure", "Simulated camera exposure. Positive brightens, negative darkens."),
        ("gamma", "Midtone brightness curve. 1 leaves the layer unchanged."),
        ("hue", "Rotates every colour around the colour wheel."),
        ("opacity", "Transparency. 0 is invisible, 1 is solid."),
        ("alpha", "Transparency. 0 is invisible, 1 is solid."),
        ("color", "Colour used by this effect."),
        ("scale", "Size of the pattern relative to the layer."),
        ("size", "Size of the affected area."),
        ("strength", "How strongly the effect is applied."),
        ("intensity", "How strongly the effect is applied."),
        ("amount", "How strongly the effect is applied. 0 disables it.")
    ]

    static func parameter(effect: String? = nil, key: String, title: String = "",
                          displaysDegrees: Bool = false) -> String {
        let normalized = key.lowercased()
        if let effect, let specific = effectParameters[effect.lowercased()]?[normalized] {
            return specific
        }
        if let match = parameterDescriptions.first(where: { normalized.contains($0.match) }) {
            return match.text
        }
        if displaysDegrees { return "Rotation applied by the effect, in degrees." }
        let label = title.isEmpty ? key : title
        return label.isEmpty ? "Adjusts this parameter." : "Adjusts \(label.lowercased())."
    }

    // MARK: - Wallpaper controls

    static let volume = "Loudness of the wallpaper's own soundtrack. Set it to 0 to keep the wallpaper silent."
    static let videoSpeed = "Playback speed of the video. 1 is normal; 0 pauses it."
    static let audioSpeed = "Playback speed of the soundtrack. Link it to the video speed to keep them in step."
    static let linkRates = "Keep the audio speed matched to the video speed."
    static let placement = "How the wallpaper is fitted to the screen when its aspect ratio differs."
    static let sceneMusic = "Play the soundtrack that ships with this wallpaper."
    static let sceneMusicVolume = "Loudness of the wallpaper's own soundtrack."

    static let musicSyncSource = """
    Music sync follows the wallpaper's own soundtrack while you can hear it. \
    Mute the wallpaper and it follows whatever else is playing on your Mac instead.
    """

    static func musicSync(_ title: String) -> String {
        switch title.lowercased() {
        case "zoom": return "Scales the picture with the beat. \(musicSyncSource)"
        case "pace": return "Speeds the video up and down with the beat. Negative values slow it on loud passages. \(musicSyncSource)"
        case "tilt": return "Rocks the picture with the beat, in degrees. \(musicSyncSource)"
        case "saturation": return "Makes colours richer on loud passages. \(musicSyncSource)"
        default: return musicSyncSource
        }
    }
}
