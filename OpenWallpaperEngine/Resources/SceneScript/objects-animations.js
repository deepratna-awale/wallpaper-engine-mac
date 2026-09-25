'use strict';
// SceneScript object model, part 2 of 5: `IAnimation` and `ITextureAnimation` over the animation
// buffer (rate, frame, playing per animation slot). The renderer keeps the state current and
// executes the commands; timeline evaluation itself is WP12, which can replace
// `__rt.objects.hooks.animation` to hand out richer objects.
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const OP = objects.OP;
    const buffer = objects.animations;
    const layout = objects.animationLayout;

    // The playback part both interfaces share. `record` is the animation's record from
    // SceneScriptObjectStore (slot, name, fps, frameCount, duration, property).
    class PlaybackState {
        constructor(record) {
            // Non-enumerable internals; `objects.detach` points them at a snapshot once the owner
            // is destroyed, so a stale reference never touches a reused slot.
            Object.defineProperty(this, '_record', { value: record });
            objects.attach(this, buffer.values, record.slot * buffer.stride, buffer.dirty, record.slot);
        }

        get frameCount() { return this._record.frameCount; }
        set frameCount(value) {}
        get duration() { return this._record.duration; }
        set duration(value) {}

        get rate() { return this._t[this._base + layout.rate]; }
        set rate(value) {
            if (typeof value !== 'number' || this._dead) return;
            this._t[this._base + layout.rate] = value;
            this._d[this._di] = 1;
        }

        play() {
            this._t[this._base + layout.playing] = 1;
            this._command(OP.animationPlay);
        }

        pause() {
            this._t[this._base + layout.playing] = 0;
            this._command(OP.animationPause);
        }

        stop() {
            this._t[this._base + layout.playing] = 0;
            this._t[this._base + layout.frame] = 0;
            this._command(OP.animationStop);
        }

        isPlaying() { return this._t[this._base + layout.playing] !== 0; }

        getFrame() { return this._t[this._base + layout.frame]; }

        setFrame(frame) {
            if (typeof frame !== 'number') return;
            this._t[this._base + layout.frame] = frame;
            this._command(OP.animationSetFrame, [frame]);
        }
    }
    objects.defineMethod(PlaybackState.prototype, '_command', function (opcode, numbers) {
        if (!this._dead) objects.push(opcode, this._record.slot, numbers);
    });

    // IAnimation: a named timeline of an object, effect, material or the scene.
    class Animation extends PlaybackState {
        get fps() { return this._record.fps; }
        set fps(value) {}
        get name() { return this._record.name; }
        set name(value) {}
    }

    // ITextureAnimation: an image's spritesheet animation. Changing it detaches it from the state
    // shared by every user of the texture; `join()` returns to it (docs).
    class TextureAnimation extends PlaybackState {
        join() { this._command(OP.animationJoin); }
    }

    objects.Animation = Animation;
    objects.TextureAnimation = TextureAnimation;

    const instances = new Map();

    // The one JS object per animation slot, so repeated `getAnimation` calls return the same object.
    objects.animationFor = function (owner, record, textured) {
        let animation = instances.get(record.slot);
        if (animation === undefined) {
            animation = objects.hooks.animation ? objects.hooks.animation(owner, record, textured) : undefined;
            if (animation === undefined) animation = textured ? new TextureAnimation(record) : new Animation(record);
            instances.set(record.slot, animation);
        }
        return animation;
    };

    // Detaches the animations of `records` (their owner was destroyed; Swift reuses the slots).
    objects.forgetAnimations = function (records) {
        for (let i = 0; i < records.length; i++) {
            const animation = instances.get(records[i].slot);
            if (animation !== undefined) objects.detach(animation, buffer.stride);
            instances.delete(records[i].slot);
        }
    };

    // The property the running script is bound to, when `owner` is its `thisObject`: what
    // `getAnimation()` without a name refers to (IThisPropertyObject: "Leave empty to get the
    // animation object bound to the current property").
    objects.currentProperty = function (owner) {
        if (rt.current === null) return undefined;
        const binding = objects.bindings.get(rt.current);
        if (!binding || objects.bindingTarget(binding) !== owner) return undefined;
        return binding.property;
    };

    // IObject.getAnimation(name?) over `records` (the owner's animation records). Null when the
    // owner has no such animation.
    objects.resolveAnimation = function (owner, records, name) {
        let found;
        if (name === undefined || name === null) {
            const property = objects.currentProperty(owner);
            if (property === undefined) return null;
            found = records.find(function (record) { return record.property === property; });
        } else {
            const key = String(name);
            found = records.find(function (record) { return record.name === key; });
        }
        return found ? objects.animationFor(owner, found, false) : null;
    };
})(this);
