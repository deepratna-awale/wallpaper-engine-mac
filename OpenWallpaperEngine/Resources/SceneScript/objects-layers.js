'use strict';
// SceneScript object model, part 4 of 5: `ILayer` and its kinds as live classes over the object
// table. `ILayer` is the union of every kind (lib.sceneScript.d.ts), so every layer has every
// member; one that does not apply to the layer's kind is inert. Numeric members are generated from
// SceneScriptObjectField's list; strings live on the object and reach the renderer as commands.
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const OP = objects.OP;
    const table = objects.table;
    const stride = table.layout.stride;
    const fields = rt.native.objects.fields;
    // SceneScriptObjectModel.maximumEmitCount.
    const MAX_EMIT = 1000000;
    const STRINGS = ['text', 'font', 'horizontalalign', 'verticalalign', 'anchor', 'alignment'];

    // Strings written this frame, flushed as one command per (slot, field) in the deferred phase.
    const pendingStrings = new Map();

    function writeString(layer, field, value) {
        if (value === undefined || value === null || layer._dead) return;
        layer._strings[field] = String(value);
        pendingStrings.set(layer._slot + ':' + field, { layer: layer, field: field });
    }

    objects.flushStrings = function () {
        pendingStrings.forEach(function (entry) {
            if (!entry.layer._dead) {
                const value = entry.field === 'name' ? entry.layer._name : entry.layer._strings[entry.field];
                objects.push(OP.setString, entry.layer._slot, undefined, [entry.field, value]);
            }
        });
        pendingStrings.clear();
    };

    // IParticleSystemInstance (`thisLayer.instance`): the particle system's `instanceoverride`
    // multipliers and control points, in the layer's own table slot.
    class ParticleInstance {
        constructor(layer) {
            Object.defineProperty(this, '_layer', { value: layer });
        }
    }

    // ILayer. `record` comes from SceneScriptObjectStore: slot, kind, id, name, parentID, strings,
    // effects, textureAnimation, animations, config.
    class Layer {
        constructor(record) {
            Object.defineProperty(this, '_record', { value: record });
            Object.defineProperty(this, '_slot', { value: record.slot });
            Object.defineProperty(this, '_id', { value: record.id });
            Object.defineProperty(this, '_name', { value: String(record.name), writable: true });
            const strings = {};
            for (let i = 0; i < STRINGS.length; i++) {
                const value = record.strings[STRINGS[i]];
                strings[STRINGS[i]] = value === undefined ? '' : String(value);
            }
            Object.defineProperty(this, '_strings', { value: strings });
            Object.defineProperty(this, '_effects', { value: null, writable: true });
            Object.defineProperty(this, '_instance', { value: null, writable: true });
            objects.attach(this, table.values, record.slot * stride, table.dirty, record.slot);
        }

        get id() { return this._id; }
        set id(value) {}

        get name() { return this._name; }
        set name(value) {
            if (value === undefined || value === null || this._dead) return;
            this._name = String(value);
            pendingStrings.set(this._slot + ':name', { layer: this, field: 'name' });
        }

        get instance() {
            if (this._instance === null) this._instance = new ParticleInstance(this);
            return this._instance;
        }
        set instance(value) {}

        getAnimation(name) { return objects.resolveAnimation(this, this._record.animations, name); }

        // The world transform the renderer wrote after its last transform pass (column-major, like
        // WE's Mat4).
        getTransformMatrix() {
            const t = this._t, base = this._base + table.layout.worldMatrix;
            const m = new Array(16);
            for (let i = 0; i < 16; i++) m[i] = t[base + i];
            return objects.mat4(m);
        }

        // "Returns the current parent layer or undefined if the layer is not parented."
        getParent() {
            if (this._record.parentID === null) return undefined;
            const parent = objects.byID.get(this._record.parentID);
            return parent === undefined ? undefined : parent;
        }

        getChildren() {
            const id = this._id;
            return objects.order.filter(function (layer) { return layer._record.parentID === id; });
        }

        // IEffectLayer.getEffect(name|index): by position, or by the effect's name.
        getEffect(nameOrIndex) {
            const effects = this._effectList();
            let effect;
            if (typeof nameOrIndex === 'number') {
                effect = effects[Math.floor(nameOrIndex)];
            } else if (nameOrIndex !== undefined && nameOrIndex !== null) {
                const name = String(nameOrIndex);
                effect = effects.find(function (candidate) { return candidate.name === name; });
            }
            return effect === undefined ? null : effect;
        }

        getEffectCount() { return this._record.effects.length; }

        // The image's spritesheet animation, or null when its texture is not animated.
        getTextureAnimation() {
            const record = this._record.textureAnimation;
            return record === null || record === undefined ? null : objects.animationFor(this, record, true);
        }

        // Sound and particle playback; inert on other kinds.
        play() {}
        pause() {}
        stop() {}
        isPlaying() { return false; }
        emitParticles(count) {}
    }
    objects.defineMethod(Layer.prototype, '_effectList', function () {
        if (this._effects === null) {
            const effects = [];
            for (let i = 0; i < this._record.effects.length; i++) {
                effects.push(new objects.Effect(this, this._record.effects[i]));
            }
            this._effects = effects;
        }
        return this._effects;
    });

    // Generated numeric members (SceneScriptObjectField).
    for (let i = 0; i < fields.length; i++) {
        const field = fields[i];
        if (field.group === 'layer') {
            objects.defineField(Layer.prototype, field.name, field.offset, field.type, field.readOnly);
        } else if (field.group === 'instance') {
            const offset = field.offset, type = field.type;
            Object.defineProperty(ParticleInstance.prototype, field.name, {
                configurable: true,
                enumerable: true,
                get: function () { return objects.read(type, this._layer._t, this._layer._base + offset); },
                set: function (value) {
                    const layer = this._layer;
                    const c = layer._dead ? undefined : objects.convert(type, value);
                    if (c === undefined) return;
                    for (let k = 0; k < c.length; k++) layer._t[layer._base + offset + k] = c[k];
                    layer._d[layer._di] = 1;
                },
            });
        }
    }
    const PLAYING = fields.find(function (field) { return field.field === 'playing'; }).offset;

    for (let i = 0; i < STRINGS.length; i++) {
        const field = STRINGS[i];
        Object.defineProperty(Layer.prototype, field, {
            configurable: true,
            enumerable: true,
            get: function () { return this._strings[field]; },
            set: function (value) { writeString(this, field, value); },
        });
    }

    // Members WE has that need engine features this app lacks yet (WP12: animation layers, bones,
    // blend shapes, attachments, runtime parenting, object-space rotation; video textures).
    const identity4 = function () { return objects.mat4(); };
    const zero3 = function () { return objects.vec3(0, 0, 0); };
    const minusOne = function () { return -1; };
    const zero = function () { return 0; };
    const none = function () { return null; };
    const no = function () { return false; };
    const P = Layer.prototype;
    [['rotateObjectSpace'], ['lookAt'], ['lookAtYaw'], ['setParent'],
        ['getAttachmentIndex', minusOne], ['getAttachmentMatrix', identity4], ['getAttachmentOrigin', zero3],
        ['getAttachmentAngles', zero3]].forEach(function (s) { objects.stub(P, 'ILayer', s[0], s[1]); });
    objects.stub(P, 'IEffectLayer', 'transformAttachmentToTexture', function () { return objects.mat3(); });
    [['getVideoTexture', none], ['getAnimationLayerCount', zero], ['getAnimationLayer', none],
        ['createAnimationLayer', none], ['playSingleAnimation', none], ['destroyAnimationLayer', no],
        ['getBoneCount', zero], ['getBoneTransform', identity4], ['setBoneTransform'],
        ['getLocalBoneTransform', identity4], ['setLocalBoneTransform'], ['getLocalBoneAngles', zero3],
        ['setLocalBoneAngles'], ['getLocalBoneOrigin', zero3], ['setLocalBoneOrigin'], ['getBoneIndex', minusOne],
        ['getBoneParentIndex', minusOne], ['applyBonePhysicsImpulse'], ['resetBonePhysicsSimulation'],
        ['getBlendShapeIndex', minusOne], ['getBlendShapeWeight', zero], ['setBlendShapeWeight']]
        .forEach(function (s) { objects.stub(P, 'IImageLayer', s[0], s[1]); });

    function setPlaying(layer, playing) {
        layer._t[layer._base + PLAYING] = playing ? 1 : 0;
        layer._d[layer._di] = 1;
    }

    function playback(layer, opcode, playing) {
        setPlaying(layer, playing);
        if (!layer._dead) objects.push(opcode, layer._slot);
    }

    class ImageLayer extends Layer {}
    class TextLayer extends Layer {}
    class ModelLayer extends Layer {}
    class GroupLayer extends Layer {}

    // ISoundLayer. `isPlaying()` reads the state the renderer keeps; `play()`/`stop()` set it at once.
    class SoundLayer extends Layer {
        play() { playback(this, OP.soundPlay, true); }
        pause() { playback(this, OP.soundPause, false); }
        stop() { playback(this, OP.soundStop, false); }
        isPlaying() { return this._t[this._base + PLAYING] !== 0; }
    }

    // IParticleSystem.
    class ParticleSystem extends Layer {
        play() { playback(this, OP.particlesPlay, true); }
        pause() { playback(this, OP.particlesPause, false); }
        stop() { playback(this, OP.particlesStop, false); }
        isPlaying() { return this._t[this._base + PLAYING] !== 0; }
        // A count is floored and clamped to [0, MAX_EMIT]; NaN (an out-of-range audio read times
        // anything) emits nothing. SceneScriptObjectModel validates it again natively.
        emitParticles(count) {
            if (this._dead) return;
            if (typeof count !== 'number') {
                objects.push(OP.particlesEmit, this._slot);
                return;
            }
            if (count !== count) return;
            objects.push(OP.particlesEmit, this._slot, [Math.max(0, Math.min(MAX_EMIT, Math.floor(count)))]);
        }
    }

    const CLASSES = { image: ImageLayer, text: TextLayer, sound: SoundLayer, particle: ParticleSystem,
        model: ModelLayer, group: GroupLayer };

    objects.makeLayer = function (record) {
        const LayerClass = CLASSES[record.kind] || Layer;
        return new LayerClass(record);
    };

    // Detaches a destroyed layer: it keeps its last values; writes and commands do nothing.
    objects.detachLayer = function (layer) {
        // Build the effects first so a later `getEffect` on the stale layer never reaches reused slots.
        layer._effectList().forEach(objects.detachEffect);
        objects.detach(layer, stride);
        objects.forgetAnimations(layer._record.animations);
        if (layer._record.textureAnimation) objects.forgetAnimations([layer._record.textureAnimation]);
    };

    objects.Layer = Layer;
    objects.ImageLayer = ImageLayer;
    objects.TextLayer = TextLayer;
    objects.SoundLayer = SoundLayer;
    objects.ParticleSystem = ParticleSystem;
    objects.ModelLayer = ModelLayer;
    objects.GroupLayer = GroupLayer;
    objects.ParticleInstance = ParticleInstance;
})(this);
