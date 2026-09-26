'use strict';
// Test-only runtime pieces for the SceneScript corpus replay (docs/scenescript-plan.md WP9),
// evaluated by `SceneScriptReplaySupport.install` after the object model's files. Property binding
// is WP8's own (SceneScriptBindingExtension); this file samples the bound properties and stands in
// for packages that have not landed yet, following the plan's contract for each:
//
// - Cursor events (WP10): an inbox kind at `EVENT_ORDER.cursor` whose `target` is an object slot;
//   only that object's scripts get the callback.
// - Determinism (test-risks S24): `Date` follows the harness clock and `Math.random` is seeded.
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    // runtime.js's READY load state: only scripts that finished loading get events.
    const READY = 5;

    const order = [];

    // The object and key a site's property lives on, or null when it no longer exists.
    function member(site) {
        const binding = site.binding;
        const target = objects.bindingTarget(binding);
        if (target === null || target === undefined) return null;
        switch (binding.kind) {
        case 'layer':
            if (binding.property.indexOf('instanceoverride.') === 0) {
                return { object: target.instance, key: binding.property.slice('instanceoverride.'.length) };
            }
            return { object: target, key: binding.property };
        case 'effect': return { object: target, key: binding.property };
        case 'material': return { object: target, key: binding.property };
        case 'scene': return { object: target, key: binding.property };
        default: return null;
        }
    }

    function has(entry) {
        return entry !== null && entry.object !== null && entry.object !== undefined && entry.key in entry.object;
    }

    // Swift → JS: `type` is number | bool | string | vec2 | vec3 | vec4 | degrees; `binding` is a
    // SceneScriptObjectBinding's JS object.
    function bind(id, type, binding) {
        order.push({ id: id, type: type, binding: binding });
    }

    // MARK: cursor (WP10 stand-in)

    rt.addEventHandler('replayCursor', rt.EVENT_ORDER.cursor, function (event) {
        const p = event.payload;
        const records = rt.records;
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.slot !== event.target || !record.enabled || record.state !== READY || record.pendingDestroy) continue;
            const cursor = { worldPosition: objects.vec3(p.x, p.y, 0), localPosition: objects.vec3(p.lx, p.ly, 0) };
            rt.invoke(record, p.name, [cursor]);
        }
    });

    // MARK: determinism

    const RealDate = global.Date;
    let now = 0;
    function ReplayDate() {
        if (!new.target) return new RealDate(now).toString();
        if (arguments.length === 0) return new RealDate(now);
        return new (Function.prototype.bind.apply(RealDate, [null].concat(Array.prototype.slice.call(arguments))))();
    }
    ReplayDate.prototype = RealDate.prototype;
    ReplayDate.now = function () { return now; };
    ReplayDate.UTC = RealDate.UTC;
    ReplayDate.parse = RealDate.parse;
    global.Date = ReplayDate;

    let seed = 0x2545F491;
    Math.random = function () {
        seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
        return seed / 4294967296;
    };

    // MARK: sampling (outside the timed frame)

    function normalize(value) {
        switch (typeof value) {
        case 'number': return value;
        case 'boolean': return value ? 1 : 0;
        case 'string': return value;
        case 'undefined': return null;
        case 'object':
            if (value === null) return null;
            if (typeof value.x === 'number') {
                const out = [value.x, value.y];
                if (typeof value.z === 'number') out.push(value.z);
                if (typeof value.w === 'number') out.push(value.w);
                return out;
            }
            return { unusable: Object.prototype.toString.call(value) };
        default: return { unusable: typeof value };
        }
    }

    // One entry per bound site, in bind order: its property's live value, else the script's value.
    function sample() {
        const out = new Array(order.length);
        for (let i = 0; i < order.length; i++) {
            const site = order[i];
            const entry = member(site);
            if (has(entry)) {
                out[i] = normalize(entry.object[entry.key]);
            } else {
                const record = rt.byId.get(site.id);
                out[i] = normalize(record === undefined ? undefined : record.value);
            }
        }
        return out;
    }

    // What a script left in `shared` (3453730450 keeps its state there): numbers must stay finite.
    function sharedNumbers() {
        const out = [];
        const shared = global.shared;
        if (shared === null || typeof shared !== 'object') return out;
        Object.keys(shared).forEach(function (key) {
            const value = shared[key];
            if (typeof value === 'number') out.push([key, value]);
        });
        return out;
    }

    Object.defineProperty(global, '__replay', {
        value: {
            bind: bind,
            sample: sample,
            sharedNumbers: sharedNumbers,
            setNow: function (milliseconds) { now = milliseconds; },
        },
        enumerable: false,
    });
})(this);
