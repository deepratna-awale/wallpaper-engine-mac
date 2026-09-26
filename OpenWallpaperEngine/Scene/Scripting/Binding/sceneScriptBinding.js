'use strict';
// Property binding (docs/scenescript-plan.md WP8; SceneScriptBindingExtension.swift): the value a
// bound script's `init(value)`/`update(value)` receive, WE's converter for what they return, and
// user property changes of bound values and script properties.
(function (global) {
    const rt = global.__rt;
    // Script id → {path, type, user, scriptUsers} (SceneScriptBoundProperty).
    const sites = new Map();
    const KEYS = ['x', 'y', 'z', 'w'];
    const COMPONENTS = { vec2: 2, vec3: 3, degrees: 3, vec4: 4 };

    // WE's own classes from baseclasses.js (global lexical bindings, not properties of `global`).
    function vector(count, c) {
        switch (count) {
        case 2: return typeof Vec2 === 'function' ? new Vec2(c[0], c[1]) : { x: c[0], y: c[1] };
        case 3: return typeof Vec3 === 'function' ? new Vec3(c[0], c[1], c[2]) : { x: c[0], y: c[1], z: c[2] };
        default:
            return typeof Vec4 === 'function' ? new Vec4(c[0], c[1], c[2], c[3]) : { x: c[0], y: c[1], z: c[2], w: c[3] };
        }
    }

    // MARK: WE's converter (scenescript64.dll 0x181620e10; plan §1.9 P3, SceneScriptPropertyType)

    // The value a property of `type` takes from `value`, as a fresh value the script can't alias,
    // or undefined when the converter rejects it (the property keeps its value).
    function convert(type, value) {
        switch (type) {
        case 'number': return typeof value === 'number' ? value : undefined;
        case 'bool': return typeof value === 'boolean' ? value : undefined;
        case 'string':
            if (value === null || value === undefined || typeof value === 'symbol') return undefined;
            return String(value);
        default: {
            const count = COMPONENTS[type];
            if (count === undefined) return undefined;
            const c = new Array(count);
            if (value !== null && (typeof value === 'object' || typeof value === 'function')) {
                for (let i = 0; i < count; i++) {
                    const component = value[KEYS[i]];
                    if (typeof component !== 'number') return undefined;
                    c[i] = component;
                }
            } else if (typeof value === 'number') {
                for (let i = 0; i < count; i++) c[i] = value;
            } else {
                return undefined;
            }
            return vector(count, c);
        }
        }
    }

    // A stored value handed to a script: vectors as fresh copies, so a script that changes its
    // argument without returning it changes nothing (test-risks S7).
    function copy(type, value) {
        const count = COMPONENTS[type];
        if (count === undefined || value === null || typeof value !== 'object') return value;
        const c = new Array(count);
        for (let i = 0; i < count; i++) c[i] = typeof value[KEYS[i]] === 'number' ? value[KEYS[i]] : 0;
        return vector(count, c);
    }

    // A user property's raw value in WE's scene forms (SceneScriptSceneValue.swift): a flag, a
    // number, vector text ("1 0.5 0", one number fills every component), text. With a condition,
    // a flag is whether the value's text equals it.
    function fromScene(type, raw, condition) {
        if (condition !== undefined && condition !== null && type === 'bool') return String(raw) === String(condition);
        switch (type) {
        case 'bool':
            if (typeof raw === 'boolean') return raw;
            if (typeof raw === 'number') return raw !== 0;
            if (raw === 'true' || raw === '1') return true;
            if (raw === 'false' || raw === '0') return false;
            return undefined;
        case 'string':
            return raw === null || raw === undefined ? undefined : String(raw);
        default: {
            const numbers = typeof raw === 'number' ? [raw]
                : typeof raw === 'boolean' ? [raw ? 1 : 0]
                    : typeof raw === 'string' ? raw.trim().split(/[\s,]+/).map(Number) : [];
            if (numbers.length === 0 || numbers.some(function (n) { return n !== n; })) return undefined;
            if (type === 'number') return numbers[0];
            const count = COMPONENTS[type];
            if (count === undefined) return undefined;
            const c = new Array(count);
            for (let i = 0; i < count; i++) c[i] = numbers.length === 1 ? numbers[0] : (i < numbers.length ? numbers[i] : 0);
            return vector(count, c);
        }
        }
    }

    // MARK: the bound property in the object model

    // How to read and write the property through the object model, or null when it is not one of
    // its members (then the record's own value is the property's value).
    function member(record) {
        const objects = rt.objects;
        const binding = record.binding;
        if (!objects || binding === null || binding === undefined) return null;
        const target = objects.bindingTarget(binding);
        if (target === null || target === undefined) return null;
        const property = String(binding.property);
        if (binding.kind === 'material') {
            return {
                read: function () { return target.getMaterialProperty(property); },
                write: function (value) { target.setMaterialProperty(property, typeof value === 'boolean' ? (value ? 1 : 0) : value); },
            };
        }
        let object = target, key = property;
        if (binding.kind === 'layer' && property.indexOf('instanceoverride.') === 0) {
            object = target.instance;
            key = property.slice('instanceoverride.'.length);
        }
        if (object === null || object === undefined || !(key in object) || typeof object[key] === 'function') return null;
        if (object === target && typeof objects.isBoundOnly === 'function' && objects.isBoundOnly(key)) {
            return {
                read: function () { return object[key]; },
                write: function (value) { objects.writeBound(object, key, value); },
            };
        }
        return {
            read: function () { return object[key]; },
            write: function (value) { object[key] = value; },
        };
    }

    function assign(record, value) {
        const access = member(record);
        if (access !== null) access.write(value);
        record.value = value;
    }

    // MARK: hooks

    rt.hooks.argument = function (record) {
        const site = sites.get(record.id);
        if (site === undefined) return record.value;
        const access = member(record);
        if (access !== null) {
            const live = access.read();
            if (live !== undefined) return live;
        }
        return copy(site.type, record.value);
    };

    rt.hooks.coerce = function (record, returned) {
        const site = sites.get(record.id);
        if (site === undefined) return returned;
        const value = convert(site.type, returned);
        if (value === undefined) return undefined;
        const access = member(record);
        if (access !== null) access.write(value);
        return value;
    };

    // Before `applyUserProperties(changed)`: values bound to a changed property take its value,
    // and script properties bound to one are injected through WE's `_Internal.updateScriptProperties`
    // into scripts that finished evaluating.
    const userPropertiesChanged = rt.hooks.userPropertiesChanged;
    rt.hooks.userPropertiesChanged = function (changed) {
        userPropertiesChanged(changed);
        if (changed === null || typeof changed !== 'object') return;
        const records = rt.records.slice();
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            const site = sites.get(record.id);
            if (site === undefined || !record.enabled) continue;
            if (site.user && Object.prototype.hasOwnProperty.call(changed, site.user.name)) {
                const value = fromScene(site.type, rawValue(changed[site.user.name]), site.user.condition);
                if (value !== undefined) assign(record, value);
            }
            injectChangedScriptProperties(record, site, changed);
        }
    };

    function rawValue(entry) {
        return entry !== null && typeof entry === 'object' ? entry.value : entry;
    }

    function injectChangedScriptProperties(record, site, changed) {
        const vars = {};
        let any = false;
        Object.keys(site.scriptUsers).forEach(function (key) {
            const user = site.scriptUsers[key];
            if (!Object.prototype.hasOwnProperty.call(changed, user.name)) return;
            const raw = rawValue(changed[user.name]);
            vars[key] = user.condition !== undefined && user.condition !== null ? String(raw) === String(user.condition) : raw;
            any = true;
        });
        if (!any || !record.exports) return;
        const declared = rt.exports(record, 'scriptProperties');
        const internal = global._Internal;
        if (declared === null || typeof declared !== 'object' || !internal) return;
        rt.call(record, '<scriptProperties>', 'idle', internal.updateScriptProperties,
            [{ scriptProperties: declared }, JSON.stringify(vars)]);
    }

    // MARK: native side

    const binding = {
        // `property` is SceneScriptBoundProperty.javaScriptObject.
        bind: function (id, property) {
            sites.set(String(id), {
                path: String(property.path),
                type: String(property.type),
                user: property.user || null,
                scriptUsers: property.scriptUsers || {},
            });
        },
        convert: convert,
    };
    Object.defineProperty(rt, 'binding', { value: binding, enumerable: false, writable: false, configurable: false });
})(this);
