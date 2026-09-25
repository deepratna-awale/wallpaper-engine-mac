import Foundation

extension Notification.Name {
    /// Posted by the sidebar when a user property changes. `object` is the wallpaper directory
    /// path; `userInfo` holds `key` and `value` (the stored string).
    static let wallpaperUserPropertyChanged = Notification.Name("WallpaperUserPropertyChanged")
}

/// Builds the JavaScript that delivers project.json user properties and audio to a web wallpaper,
/// the way Wallpaper Engine does (`window.wallpaperPropertyListener.applyUserProperties` and
/// `window.wallpaperRegisterAudioListener`).
enum WebWallpaperPropertyBridge {
    /// UserDefaults key of the sidebar's stored values for a wallpaper.
    static func storageKey(for wallpaperDirectory: URL) -> String {
        "SceneUserProperties.\(wallpaperDirectory.path)"
    }

    struct Property: Equatable {
        var type: String
        var defaultValue: String
    }

    /// Declared properties from a project.json root object, keyed by name.
    static func declaredProperties(projectRoot: [String: Any]) -> [String: Property] {
        let raw = ((projectRoot["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]) ?? [:]
        var result: [String: Property] = [:]
        for (key, entry) in raw {
            let type = (entry["type"] as? String)?.lowercased() ?? "text"
            // Notice rows carry no value WE would deliver.
            guard type != "text", type != "group" else { continue }
            var value = entry["value"].map(sceneUserPropertyString)
            if value == nil, type == "combo",
               let first = (entry["options"] as? [[String: Any]])?.first?["value"] {
                value = sceneUserPropertyString(first)
            }
            result[key] = Property(type: type, defaultValue: value ?? (type == "bool" ? "false" : ""))
        }
        return result
    }

    static func declaredProperties(wallpaperDirectory: URL) -> [String: Property] {
        guard let data = try? Data(contentsOf: wallpaperDirectory.appending(path: "project.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return declaredProperties(projectRoot: root)
    }

    /// The JSON value WE hands the page: numbers for sliders, booleans for bools, and the raw
    /// string ("r g b" for colors, the option value for combos) otherwise.
    static func jsonValue(type: String, value: String) -> Any {
        switch type {
        case "bool":
            return value.lowercased() == "true" || value == "1"
        case "slider":
            return Double(value).map { $0.rounded() == $0 && abs($0) < 1e15 ? NSNumber(value: Int64($0)) : NSNumber(value: $0) } ?? value
        default:
            return value
        }
    }

    /// `{key: {value: …}}` for the given stored values (keys absent from `properties` are skipped).
    static func payload(properties: [String: Property], values: [String: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            guard let property = properties[key] else { continue }
            result[key] = ["type": property.type, "value": jsonValue(type: property.type, value: value)]
        }
        return result
    }

    /// Stored values merged over project defaults, for every declared property.
    static func currentValues(properties: [String: Property], stored: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for (key, property) in properties {
            values[key] = stored[key] ?? property.defaultValue
        }
        return values
    }

    static func applyUserPropertiesScript(_ payload: [String: Any]) -> String? {
        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function(){var l=window.wallpaperPropertyListener;\
        if(l&&typeof l.applyUserProperties==='function'){try{l.applyUserProperties(\(json));}catch(e){console.error(e);}}})();
        """
    }

    static func applyGeneralPropertiesScript(fps: Int) -> String {
        """
        (function(){var l=window.wallpaperPropertyListener;\
        if(l&&typeof l.applyGeneralProperties==='function'){try{l.applyGeneralProperties({fps:\(fps)});}catch(e){console.error(e);}}})();
        """
    }

    /// 128 values: 64 left then 64 right, each clamped to 0…1.
    static func audioArray(left: [Float], right: [Float]) -> [Float] {
        func band(_ values: [Float]) -> [Float] {
            (0..<64).map { index in index < values.count ? min(max(values[index], 0), 1) : 0 }
        }
        return band(left) + band(right)
    }

    static func audioDeliveryScript(_ samples: [Float]) -> String {
        let list = samples.map { value -> String in
            value == 0 ? "0" : String(format: "%.4f", value)
        }.joined(separator: ",")
        return "window.__oweDeliverAudio&&window.__oweDeliverAudio([\(list)]);"
    }

    static let audioMessageName = "oweAudioListener"

    /// Injected at document start: WE's registration functions. Media/other listeners are
    /// accepted and never called.
    static let bootstrapScript = """
    (function(){
      if (window.__oweBridge) return; window.__oweBridge = true;
      var audio = [];
      window.wallpaperRegisterAudioListener = function(cb){
        if (typeof cb !== 'function') return;
        audio.push(cb);
        try { window.webkit.messageHandlers.\(audioMessageName).postMessage(audio.length); } catch(e) {}
      };
      window.__oweDeliverAudio = function(values){
        for (var i = 0; i < audio.length; i++) { try { audio[i](values); } catch(e) { console.error(e); } }
      };
      var noop = function(){};
      window.wallpaperRegisterMediaStatusListener = noop;
      window.wallpaperRegisterMediaPropertiesListener = noop;
      window.wallpaperRegisterMediaThumbnailListener = noop;
      window.wallpaperRegisterMediaPlaybackListener = noop;
      window.wallpaperRegisterMediaTimelineListener = noop;
    })();
    """
}
