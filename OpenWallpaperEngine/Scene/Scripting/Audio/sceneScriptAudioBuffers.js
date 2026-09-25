'use strict';
// `engine.registerAudioBuffers(resolution)` (WP5, docs/scenescript-plan.md; lib.sceneScript.d.ts
// IEngine and AudioBuffers). `__rt.native.audioBuffers[resolution]` is a Float32Array of
// left | right | average that SceneScriptAudioBuffers.swift refills in place before every frame;
// the arrays handed out are views into it, so they are live, like WE's.
(function (global) {
    const rt = global.__rt;
    const stores = rt.native.audioBuffers;

    function registerAudioBuffers(resolution) {
        rt.requireGlobalScope('registerAudioBuffers');
        if (resolution !== 16 && resolution !== 32 && resolution !== 64) {
            throw new Error('Resolution must be either 16, 32 or 64.');
        }
        const store = stores[resolution];
        return {
            left: store.subarray(0, resolution),
            right: store.subarray(resolution, 2 * resolution),
            average: store.subarray(2 * resolution, 3 * resolution),
        };
    }

    // WP4's engine file adds its members to the same object, whichever runs first.
    const engine = global.engine !== undefined ? global.engine : {};
    engine.registerAudioBuffers = registerAudioBuffers;
    if (engine.AUDIO_RESOLUTION_16 === undefined) engine.AUDIO_RESOLUTION_16 = 16;
    if (engine.AUDIO_RESOLUTION_32 === undefined) engine.AUDIO_RESOLUTION_32 = 32;
    if (engine.AUDIO_RESOLUTION_64 === undefined) engine.AUDIO_RESOLUTION_64 = 64;
    global.engine = engine;
})(this);
