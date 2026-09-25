/// `createScriptProperties` as WE runs it: WE's own builder from `baseclasses.js` (authored
/// defaults, a combo's first option, the `_config` entries with min/max/options), then the
/// scene's `scriptproperties` through `_Internal.updateScriptProperties` (declared keys only; a
/// string becomes a `Vec3` when the default is one). The fallback builder is the same code as
/// `assets/scripts/jsclasses/baseclasses.js`, for when no WE runtime is loaded.
enum SceneScriptPropertiesShim {
    /// Evaluated with `g` bound to the global object, after `baseclasses.js`. The scene's values
    /// are read from `g.__scriptProperties`.
    static let source = #"""
    (function(g){
        if(g.__scriptPropertiesShim)return;
        g.__scriptPropertiesShim=true;
        const weCreate=typeof g.createScriptProperties==='function'?g.createScriptProperties:function(){var vars={};var obj={order:0,
            addSlider:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label,min:o.min,max:o.max,mode:(o.integer===true)?'int':undefined};return obj;},
            addCheckbox:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label};return obj;},
            addText:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label};return obj;},
            addCombo:function(o){vars[o.name]=o.options[0].value;vars[o.name+'_config']={order:obj.order++,label:o.label,options:o.options,mode:'combo'};return obj;},
            addColor:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label};return obj;},
            finish:function(){return vars;}};return obj;};
        const update=(g._Internal&&typeof g._Internal.updateScriptProperties==='function')?g._Internal.updateScriptProperties.bind(g._Internal):function(script,json){
            const vars=JSON.parse(json);
            Object.keys(vars).forEach(function(key){
                if(script.scriptProperties.hasOwnProperty(key)){
                    script.scriptProperties[key]=(typeof g.Vec3==='function'&&script.scriptProperties[key] instanceof g.Vec3)?new g.Vec3(vars[key]):vars[key];
                }
            });
        };
        g.createScriptProperties=function(){
            const api=weCreate.call(g);
            const finish=api.finish;
            api.finish=function(){
                const script={scriptProperties:finish.call(api)};
                update(script,JSON.stringify(g.__scriptProperties||{}));
                return script.scriptProperties;
            };
            return api;
        };
    })(this);
    """#
}
