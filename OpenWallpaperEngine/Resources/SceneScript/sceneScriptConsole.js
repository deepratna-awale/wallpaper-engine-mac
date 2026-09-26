'use strict';
// The `console` global (lib.sceneScript.d.ts IConsole; WP4, docs/scenescript-plan.md): `log` and
// `error` with any number of arguments, each converted with String() and joined by spaces, sent to
// SceneScriptConsole.swift with the id of the script that is running.
(function (global) {
    const rt = global.__rt;

    function text(values) {
        const parts = [];
        for (let i = 0; i < values.length; i++) {
            try {
                parts.push(String(values[i]));
            } catch (error) {
                // No usable toString (Object.create(null), one that throws): log its tag instead.
                parts.push(Object.prototype.toString.call(values[i]));
            }
        }
        return parts.join(' ');
    }

    function write(isError, values) {
        rt.native.consoleWrite(isError, text(values), rt.current === null ? '' : String(rt.current));
    }

    // Replaces JavaScriptCore's own console, which writes nowhere useful.
    Object.defineProperty(global, 'console', {
        value: {
            log: function () { write(false, arguments); },
            error: function () { write(true, arguments); },
        },
        enumerable: false, writable: true, configurable: true,
    });
})(this);
