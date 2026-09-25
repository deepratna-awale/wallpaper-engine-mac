import Cocoa
import JavaScriptCore

extension Notification.Name {
    static let sceneUserPropertiesDidChange = Notification.Name("SceneUserPropertiesDidChange")
    static let audioCapturePermissionMissing = Notification.Name("AudioCapturePermissionMissing")
    static let videoMusicSyncAudioLevelDidChange = Notification.Name("VideoMusicSyncAudioLevelDidChange")
    static let videoMusicSyncSettingsDidChange = Notification.Name("VideoMusicSyncSettingsDidChange")
    static let sceneMusicSettingsDidChange = Notification.Name("SceneMusicSettingsDidChange")
}

final class AudioReactiveScriptEngine {
    static let shared = AudioReactiveScriptEngine()

    /// WE scripts are authored as ES modules (`export function update`, `export let __workshopId`, etc.),
    /// but JSContext.evaluateScript runs plain (non-module) scripts, where `export` is a syntax error that
    /// silently aborts the whole script under our exception handler. Strip every export keyword so the
    /// declarations still run as ordinary top-level statements.
    /// Wraps a 2- or 3-component input in the script runtime's Vec2/Vec3 so scripts can mutate it.
    private static func vectorInput(_ input: Any, in context: JSContext?) -> JSValue? {
        guard let context else { return nil }
        let components: [Float]
        if let floats = input as? [Float] {
            components = floats
        } else if let doubles = input as? [Double] {
            components = doubles.map(Float.init)
        } else {
            return nil
        }
        guard components.count == 2 || components.count == 3 else { return nil }
        let arguments = components.map { String($0) }.joined(separator: ",")
        let value = context.evaluateScript("new Vec\(components.count)(\(arguments))")
        return value?.isObject == true ? value : nil
    }

    /// Wallpaper Engine's own script runtime, read from the configured assets folder. Resolved
    /// once per launch; nil when no assets directory is configured, in which case the built-in
    /// shim is used on its own.
    nonisolated(unsafe) private static var cachedRuntimeSource: String??

    static var wallpaperEngineRuntimeSource: String? {
        if let cachedRuntimeSource { return cachedRuntimeSource }
        let resolved = loadWallpaperEngineRuntime()
        cachedRuntimeSource = .some(resolved)
        if resolved != nil {
            OWELog.info(.script, "Loaded Wallpaper Engine script runtime")
        }
        return resolved
    }

    private static func loadWallpaperEngineRuntime() -> String? {
        guard let assets = WallpaperEngineAssets.directory else { return nil }
        let scripts = assets.appending(path: "scripts")

        var pieces: [String] = []
        // Modules reference each other with inconsistent casing (`import * as WEMath from 'WEMath'`
        // vs wemath.js), so resolve them through a lower-cased registry.
        pieces.append("""
            this.__weModules = this.__weModules || {};
            this.__requireModule = function(name) {
                var key = String(name).toLowerCase();
                return this.__weModules[key] || this[key] || {};
            };
            """)
        if let base = try? String(contentsOf: scripts.appending(path: "jsclasses/baseclasses.js"), encoding: .utf8) {
            pieces.append(base)
        }

        // Each jsmodule is an ES module; expose it as a registry entry so rewritten imports resolve.
        let moduleDirectory = scripts.appending(path: "jsmodules")
        if let files = try? FileManager.default.contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension.lowercased() == "js" {
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                let exported = exportedNames(in: source)
                guard !exported.isEmpty else { continue }
                let body = stripESModuleExports(source)
                let returned = exported.map { "\($0): \($0)" }.joined(separator: ", ")
                pieces.append("""
                    this.__weModules['\(name)'] = (function(){ \(body)
                    return { \(returned) }; }).call(this);
                    this.\(name) = this.__weModules['\(name)'];
                    """)
            }
        }
        return pieces.count > 1 ? pieces.joined(separator: "\n") : nil
    }

    private static func exportedNames(in source: String) -> [String] {
        let pattern = #"(?m)^[ \t]*export[ \t]+(?:function|let|const|var|class)[ \t]+(\w+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        return expression.matches(in: source, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
    }

    private static func stripESModuleExports(_ script: String) -> String {                // `[ \t]*` rather than `\s*`: the latter swallows the preceding blank line, which
                // shifts every following line number and makes JS error reports point at the wrong line.
                var source = script.replacingOccurrences(of: #"(^|\n)[ \t]*export[ \t]+(function|let|const|var|class|default)"#,
                                                                                                 with: "$1$2", options: .regularExpression)
                source = source.replacingOccurrences(of: #"(?m)^\s*import\s+\*\s+as\s+(\w+)\s+from\s+['\"](\w+)['\"]\s*;?"#,
                                                     with: "const $1 = __requireModule('$2');", options: .regularExpression)
                source = source.replacingOccurrences(of: #"(?m)^\s*import\s*\{([^}]+)\}\s*from\s*['\"](\w+)['\"]\s*;?"#,
                                                     with: "const {$1} = __requireModule('$2');", options: .regularExpression)
                return source
    }

        private static let compatibilityBootstrap = #"""
        (function(g) {
            if (g.__sceneScriptReady) return;
            g.__sceneScriptReady = true;
            const number = (v, fallback = 0) => Number.isFinite(Number(v)) ? Number(v) : fallback;
            const parts = v => typeof v === 'string' ? v.trim().split(/[ ,]+/).map(Number) : [];
            class VectorBase {
                _values(v) { if (typeof v === 'number') return this._a.map(() => v); return this._a.map((_, i) => number(v && v[['x','y','z','w'][i]], 0)); }
                lengthSqr() { return this._a.reduce((s, v) => s + v * v, 0); }
                length() { return Math.sqrt(this.lengthSqr()); }
                distanceSqr(v) { return this.subtract(v).lengthSqr(); }
                distance(v) { return Math.sqrt(this.distanceSqr(v)); }
                normalize() { const l = this.length(); return l ? this.divide(l) : this.copy(); }
                copy() { return new this.constructor(...this._a); }
                equals(v) { return this._a.every((x, i) => x === this._values(v)[i]); }
                isFinite() { return this._a.every(Number.isFinite); }
                negate() { return new this.constructor(...this._a.map(v => -v)); }
                add(v) { const b=this._values(v); return new this.constructor(...this._a.map((x,i)=>x+b[i])); }
                subtract(v) { const b=this._values(v); return new this.constructor(...this._a.map((x,i)=>x-b[i])); }
                multiply(v) { const b=this._values(v); return new this.constructor(...this._a.map((x,i)=>x*b[i])); }
                divide(v) { const b=this._values(v); return new this.constructor(...this._a.map((x,i)=>x/b[i])); }
                dot(v) { const b=this._values(v); return this._a.reduce((s,x,i)=>s+x*b[i],0); }
                reflect(n) { return this.subtract(n.multiply(2*this.dot(n))); }
                project(v) { const d=v.dot(v); return d ? v.multiply(this.dot(v)/d) : new this.constructor(); }
                mix(v,a) { const b=this._values(v), t=this._values(a); return new this.constructor(...this._a.map((x,i)=>x+(b[i]-x)*t[i])); }
                min(v) { const b=this._values(v); return new this.constructor(...this._a.map((x,i)=>Math.min(x,b[i]))); }
                max(v) { const b=this._values(v); return new this.constructor(...this._a.map((x,i)=>Math.max(x,b[i]))); }
                clamp(a,b) { return this.max(typeof a==='number'?new this.constructor(...this._a.map(()=>a)):a).min(typeof b==='number'?new this.constructor(...this._a.map(()=>b)):b); }
                abs(){return new this.constructor(...this._a.map(Math.abs));} sign(){return new this.constructor(...this._a.map(Math.sign));}
                round(){return new this.constructor(...this._a.map(Math.round));} floor(){return new this.constructor(...this._a.map(Math.floor));}
                ceil(){return new this.constructor(...this._a.map(Math.ceil));} fract(){return new this.constructor(...this._a.map(x=>x-Math.floor(x)));}
                mod(v){const b=this._values(v);return new this.constructor(...this._a.map((x,i)=>((x%b[i])+b[i])%b[i]));}
                step(e){const b=this._values(e);return new this.constructor(...this._a.map((x,i)=>x<b[i]?0:1));}
                smoothStep(a,b){const lo=this._values(a),hi=this._values(b);return new this.constructor(...this._a.map((x,i)=>{let t=Math.max(0,Math.min(1,(x-lo[i])/(hi[i]-lo[i])));return t*t*(3-2*t);}));}
                toString(){return this._a.join(' ');}
            }
            class Vec2 extends VectorBase { constructor(x=0,y){super();const p=parts(x);this.x=p.length?p[0]:number(x);this.y=p.length?p[1]:number(y,x&&x.y!==undefined?x.y:this.x);} get _a(){return [this.x,this.y];} perpendicular(){return new Vec2(-this.y,this.x);} angle(){return Math.atan2(this.y,this.x);} angleBetween(v){return Math.acos(Math.max(-1,Math.min(1,this.normalize().dot(v.normalize()))));} rotate(a){const c=Math.cos(a),s=Math.sin(a);return new Vec2(this.x*c-this.y*s,this.x*s+this.y*c);} }
            class Vec3 extends VectorBase { constructor(x=0,y,z){super();const p=parts(x);this.x=p.length?p[0]:number(x);this.y=p.length?p[1]:number(y,x&&x.y!==undefined?x.y:this.x);this.z=p.length?p[2]:number(z,x&&x.z!==undefined?x.z:this.x);} get _a(){return [this.x,this.y,this.z];} cross(v){return new Vec3(this.y*v.z-this.z*v.y,this.z*v.x-this.x*v.z,this.x*v.y-this.y*v.x);} refract(n,e){const d=this.dot(n),k=1-e*e*(1-d*d);return k<0?new Vec3():this.multiply(e).subtract(n.multiply(e*d+Math.sqrt(k)));} angleBetween(v){return Math.acos(Math.max(-1,Math.min(1,this.normalize().dot(v.normalize()))));} toSpherical(){return new Vec3(this.length(),Math.atan2(this.z,this.x),Math.acos(this.y/Math.max(this.length(),1e-9)));} static fromSpherical(v){return new Vec3(v.x*Math.sin(v.z)*Math.cos(v.y),v.x*Math.cos(v.z),v.x*Math.sin(v.z)*Math.sin(v.y));} }
            class Vec4 extends VectorBase { constructor(x=0,y,z,w){super();const p=parts(x);this.x=p.length?p[0]:number(x);this.y=p.length?p[1]:number(y,x&&x.y!==undefined?x.y:this.x);this.z=p.length?p[2]:number(z,x&&x.z!==undefined?x.z:this.x);this.w=p.length?p[3]:number(w,x&&x.w!==undefined?x.w:this.x);} get _a(){return [this.x,this.y,this.z,this.w];} }
            class MatBase { constructor(size, values){this.size=size;this.values=values||Array.from({length:size*size},(_,i)=>i%(size+1)===0?1:0);} copy(){return new this.constructor(this.values.slice());} equals(m){return this.values.every((v,i)=>v===m.values[i]);} add(m){return new this.constructor(this.values.map((v,i)=>v+m.values[i]));} subtract(m){return new this.constructor(this.values.map((v,i)=>v-m.values[i]));} multiply(v){if(typeof v==='number')return new this.constructor(this.values.map(x=>x*v));if(v&&v.values){let r=Array(this.size*this.size).fill(0);for(let y=0;y<this.size;y++)for(let x=0;x<this.size;x++)for(let k=0;k<this.size;k++)r[y*this.size+x]+=this.values[y*this.size+k]*v.values[k*this.size+x];return new this.constructor(r);}return this.transformPoint(v);} transpose(){let r=[];for(let y=0;y<this.size;y++)for(let x=0;x<this.size;x++)r[y*this.size+x]=this.values[x*this.size+y];return new this.constructor(r);} toString(){return this.values.join(' ');} }
            class Mat3 extends MatBase { constructor(v){super(3,v);} static identity(){return new Mat3();} static fromTranslation(v){return new Mat3().translate(v);} static fromScale(v){return new Mat3().scale(v);} static fromRotation(a){return new Mat3().rotate(a);} translation(){return new Vec2(this.values[2],this.values[5]);} translate(v){const m=new Mat3([1,0,v.x,0,1,v.y,0,0,1]);return this.multiply(m);} rotate(a){const c=Math.cos(a),s=Math.sin(a);return this.multiply(new Mat3([c,-s,0,s,c,0,0,0,1]));} scale(v){v=typeof v==='number'?new Vec2(v,v):v;return this.multiply(new Mat3([v.x,0,0,0,v.y,0,0,0,1]));} transformPoint(v){const a=this.values;return new Vec2(a[0]*v.x+a[1]*v.y+a[2],a[3]*v.x+a[4]*v.y+a[5]);} transformDirection(v){const a=this.values;return new Vec2(a[0]*v.x+a[1]*v.y,a[3]*v.x+a[4]*v.y);} angle(){return Math.atan2(this.values[3],this.values[0]);} determinant(){const a=this.values;return a[0]*(a[4]*a[8]-a[5]*a[7])-a[1]*(a[3]*a[8]-a[5]*a[6])+a[2]*(a[3]*a[7]-a[4]*a[6]);} }
            class Mat4 extends MatBase { constructor(v){super(4,v);} static identity(){return new Mat4();} static fromTranslation(v){return new Mat4().translate(v);} static fromScale(v){return new Mat4().scale(v);} translation(){return new Vec3(this.values[3],this.values[7],this.values[11]);} right(){return new Vec3(this.values[0],this.values[4],this.values[8]);} up(){return new Vec3(this.values[1],this.values[5],this.values[9]);} forward(){return new Vec3(this.values[2],this.values[6],this.values[10]);} translate(v){v=v.z===undefined?new Vec3(v.x,v.y,0):v;const m=new Mat4([1,0,0,v.x,0,1,0,v.y,0,0,1,v.z,0,0,0,1]);return this.multiply(m);} scale(v){v=typeof v==='number'?new Vec3(v,v,v):v;return this.multiply(new Mat4([v.x,0,0,0,0,v.y,0,0,0,0,v.z,0,0,0,0,1]));} transformPoint(v){const a=this.values;return new Vec3(a[0]*v.x+a[1]*v.y+a[2]*v.z+a[3],a[4]*v.x+a[5]*v.y+a[6]*v.z+a[7],a[8]*v.x+a[9]*v.y+a[10]*v.z+a[11]);} transformDirection(v){const a=this.values;return new Vec3(a[0]*v.x+a[1]*v.y+a[2]*v.z,a[4]*v.x+a[5]*v.y+a[6]*v.z,a[8]*v.x+a[9]*v.y+a[10]*v.z);} }
            g.Vec2=Vec2; g.Vec3=Vec3; g.Vec4=Vec4; g.Mat3=Mat3; g.Mat4=Mat4;
            g.WEMath={smoothStep:(a,b,x)=>{let t=Math.max(0,Math.min(1,(x-a)/(b-a)));return t*t*(3-2*t);},mix:(a,b,t)=>a+(b-a)*t,deg2rad:d=>d*Math.PI/180,rad2deg:r=>r*180/Math.PI};
            g.WEVector={angleVector2:a=>new Vec2(Math.cos(a),Math.sin(a)),vectorAngle2:v=>Math.atan2(v.y,v.x)};
            g.WEColor={rgb2hsv:c=>{let r=c.x,gc=c.y,b=c.z,m=Math.max(r,gc,b),n=Math.min(r,gc,b),d=m-n,h=0;if(d){if(m===r)h=((gc-b)/d)%6;else if(m===gc)h=(b-r)/d+2;else h=(r-gc)/d+4;h/=6;if(h<0)h+=1;}return new Vec3(h,m?d/m:0,m);},hsv2rgb:c=>{let h=c.x*6,s=c.y,v=c.z,i=Math.floor(h),f=h-i,p=v*(1-s),q=v*(1-f*s),t=v*(1-(1-f)*s);return [new Vec3(v,t,p),new Vec3(q,v,p),new Vec3(p,v,t),new Vec3(p,q,v),new Vec3(t,p,v),new Vec3(v,p,q)][((i%6)+6)%6];},normalizeColor:c=>new Vec3(c.x/255,c.y/255,c.z/255),expandColor:c=>new Vec3(c.x*255,c.y*255,c.z*255)};
            class AudioBuffers { constructor(left=[],right=[]){this.left=left;this.right=right;this.average=left.map((v,i)=>(v+(right[i]||0))/2);} }
            g.AudioBuffers=AudioBuffers;
            // WE's createScriptProperties (assets/scripts/jsclasses/baseclasses.js) gives each property
            // its authored default (a combo's first option) plus its `_config`; the fallback below is
            // the same code for when no WE runtime is loaded. The scene's `scriptproperties` win.
            const weCreateScriptProperties=typeof g.createScriptProperties==='function'?g.createScriptProperties:function(){var vars={};var obj={order:0,addSlider:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label,min:o.min,max:o.max,mode:(o.integer===true)?'int':undefined};return obj;},addCheckbox:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label};return obj;},addText:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label};return obj;},addCombo:function(o){vars[o.name]=o.options[0].value;vars[o.name+'_config']={order:obj.order++,label:o.label,options:o.options,mode:'combo'};return obj;},addColor:function(o){vars[o.name]=o.value;vars[o.name+'_config']={order:obj.order++,label:o.label};return obj;},finish:function(){return vars;}};return obj;};
            g.createScriptProperties=function(){const api=weCreateScriptProperties.call(g);const finish=api.finish;api.finish=function(){const vars=finish.call(api);const authored=g.__scriptProperties||{};for(const key of Object.keys(authored))vars[key]=authored[key];return vars;};return api;};
            g.shared=g.shared||{};
            g.console={log:(...a)=>__consoleLog(a.join(' ')),error:(...a)=>__consoleError(a.join(' '))};
            g.localStorage={set:(k,v,s)=>__storageSet(String(k),JSON.stringify(v),s||0),get:(k,d,s)=>{let v=__storageGet(String(k),s||0);return v===null||v===undefined?d:JSON.parse(v);},delete:(k,s)=>__storageDelete(String(k),s||0),clear:s=>__storageClear(s||0)};
            let timerID=1,timers=[];g.setTimeout=(f,ms)=>{let id=timerID++;timers.push({id:id,f:f,t:ms/1000,repeat:0});return id;};g.setInterval=(f,ms)=>{let id=timerID++;timers.push({id:id,f:f,t:ms/1000,repeat:ms/1000});return id;};g.clearTimeout=g.clearInterval=id=>{let i=timers.findIndex(t=>t.id===id);if(i>=0)timers.splice(i,1);};g.__tickTimers=dt=>{for(let i=timers.length-1;i>=0;i--){timers[i].t-=dt;if(timers[i].t<=0){try{timers[i].f();}catch(e){console.error(e);}if(timers[i].repeat)timers[i].t+=timers[i].repeat;else timers.splice(i,1);}}};
            g.__weModules=g.__weModules||{};
            g.__requireModule=g.__requireModule||function(n){var k=String(n).toLowerCase();return g.__weModules[k]||g[k]||{};};
            g.__pendingLayerCreations=g.__pendingLayerCreations||[];
            g.__camerashake=g.__camerashake||0;
            g.__pendingLayerRemovals=g.__pendingLayerRemovals||[];
            g.__pendingLayerOrder=g.__pendingLayerOrder||[];
            g.__decorateLayer=function(layer){
                                if(!layer)return layer;
                                layer.getAnimation=layer.getAnimation||function(name){
                                        const key=String(name||'default');
                                        layer.__animations=layer.__animations||{};
                                        if(layer.__animations[key])return layer.__animations[key];
                                        let frame=0,rate=1,playing=true,ended=[];
                                        const animation={fps:60,frameCount:0,duration:0,name:key,get rate(){return rate;},set rate(v){rate=Number(v)||0;},
                                            play:function(){playing=true;},pause:function(){playing=false;},stop:function(){playing=false;frame=0;},
                                            isPlaying:function(){return playing;},getFrame:function(){return frame;},setFrame:function(v){frame=Number(v)||0;},
                                            join:function(){return animation;},
                                            addEndedCallback:function(callback){if(typeof callback==='function')ended.push(callback);},
                                            __tick:function(dt){if(playing){frame+=dt*animation.fps*rate;}}
                                        }; layer.__animations[key]=animation; return animation;
                                };
                                if(!layer.particleSystem){
                                    let playing=true, instance={alpha:1,size:1,count:0,speed:1,lifetime:1,rate:1,colorn:new Vec4(1,1,1,1),controlpoint0:new Vec3(),controlpoint1:new Vec3(),controlpoint2:new Vec3(),controlpoint3:new Vec3(),controlpoint4:new Vec3(),controlpoint5:new Vec3(),controlpoint6:new Vec3(),controlpoint7:new Vec3()};
                                    layer.particleSystem={play:function(){playing=true;},pause:function(){playing=false;},stop:function(){playing=false;},isPlaying:function(){return playing;},emitParticles:function(count){instance.count+=Number(count)||1;},instance:instance};
                                }
                                layer.getTextureAnimation=layer.getTextureAnimation||function(){return layer.__textureAnimation||(layer.__textureAnimation={frameCount:0,duration:0,rate:1,play:function(){},pause:function(){},stop:function(){},isPlaying:function(){return false;},getFrame:function(){return 0;},setFrame:function(){},join:function(){}});};
                                layer.getVideoTexture=layer.getVideoTexture||function(){return layer.__videoTexture||(layer.__videoTexture={duration:0,rate:1,loop:true,play:function(){},pause:function(){},stop:function(){},isPlaying:function(){return false;},getCurrentTime:function(){return 0;},setCurrentTime:function(){},addEndedCallback:function(){}});};
                                layer.getAnimationLayerCount=layer.getAnimationLayerCount||(()=>0);layer.getAnimationLayer=layer.getAnimationLayer||(()=>null);
                                layer.createAnimationLayer=layer.createAnimationLayer||function(animation,config){let value={name:String(animation||''),fps:60,frameCount:0,duration:0,rate:1,blend:1,visible:true,play:function(){},pause:function(){},stop:function(){},isPlaying:function(){return false;},getFrame:function(){return 0;},setFrame:function(){},addEndedCallback:function(){}};layer.__animationLayers=layer.__animationLayers||[];layer.__animationLayers.push(value);layer.getAnimationLayerCount=()=>layer.__animationLayers.length;layer.getAnimationLayer=(name)=>typeof name==='number'?layer.__animationLayers[name]:layer.__animationLayers.find(item=>item.name===String(name));return value;};
                                layer.playSingleAnimation=layer.playSingleAnimation||layer.createAnimationLayer;layer.destroyAnimationLayer=layer.destroyAnimationLayer||function(value){let list=layer.__animationLayers||[];let index=typeof value==='number'?value:list.indexOf(value);if(index<0&&value)index=list.findIndex(item=>item.name===String(value));if(index<0)return false;list.splice(index,1);return true;};
                                layer.getMaterial=layer.getMaterial||(()=>({}));layer.getMaterialCount=layer.getMaterialCount||(()=>0);layer.setMaterialProperty=layer.setMaterialProperty||(()=>{});layer.executeMaterialFunction=layer.executeMaterialFunction||(()=>{});
                                layer.transformAttachmentToTexture=layer.transformAttachmentToTexture||(()=>new Mat3());layer.getBoneCount=layer.getBoneCount||(()=>0);layer.getBoneTransform=layer.getBoneTransform||(()=>new Mat4());layer.setBoneTransform=layer.setBoneTransform||(()=>{});layer.getLocalBoneTransform=layer.getLocalBoneTransform||(()=>new Mat4());layer.setLocalBoneTransform=layer.setLocalBoneTransform||(()=>{});layer.getLocalBoneAngles=layer.getLocalBoneAngles||(()=>new Vec3());layer.setLocalBoneAngles=layer.setLocalBoneAngles||(()=>{});layer.getLocalBoneOrigin=layer.getLocalBoneOrigin||(()=>new Vec3());layer.setLocalBoneOrigin=layer.setLocalBoneOrigin||(()=>{});layer.getBoneIndex=layer.getBoneIndex||(()=>-1);layer.getBoneParentIndex=layer.getBoneParentIndex||(()=>-1);layer.applyBonePhysicsImpulse=layer.applyBonePhysicsImpulse||(()=>{});layer.resetBonePhysicsSimulation=layer.resetBonePhysicsSimulation||(()=>{});layer.getBlendShapeIndex=layer.getBlendShapeIndex||(()=>-1);layer.getBlendShapeWeight=layer.getBlendShapeWeight||(()=>0);layer.setBlendShapeWeight=layer.setBlendShapeWeight||(()=>{});
                                layer.isPlaying=layer.isPlaying||(()=>false);layer.play=layer.play||(()=>{});layer.pause=layer.pause||(()=>{});layer.stop=layer.stop||(()=>{});layer.volume=layer.volume===undefined?1:layer.volume;
                                layer.transformAttachmentToTexture=layer.transformAttachmentToTexture||(()=>new Mat3());layer.rotateObjectSpace=layer.rotateObjectSpace||function(value){layer.angles=layer.angles.add(value);};layer.lookAt=layer.lookAt||(()=>{});layer.lookAtYaw=layer.lookAtYaw||(()=>{});layer.setParent=layer.setParent||(()=>{});layer.getAttachmentIndex=layer.getAttachmentIndex||(()=>-1);layer.getAttachmentMatrix=layer.getAttachmentMatrix||(()=>new Mat4());layer.getAttachmentOrigin=layer.getAttachmentOrigin||(()=>new Vec3());layer.getAttachmentAngles=layer.getAttachmentAngles||(()=>new Vec3());
                                layer.getEffect=layer.getEffect||(()=>null);layer.getEffectCount=layer.getEffectCount||(()=>0);
                                layer.getParent=layer.getParent||(()=>null);layer.getChildren=layer.getChildren||(()=>[]);layer.getChildCount=layer.getChildCount||(()=>0);
                                layer.getTransformMatrix=layer.getTransformMatrix||(()=>new Mat4());layer.localToWorld=layer.localToWorld||(v=>v.copy?v.copy():v);layer.worldToLocal=layer.worldToLocal||(v=>v.copy?v.copy():v);
                                return layer;
                        };
            g.__dispatchRuntimeEvents=function(dt) {
                if (typeof resizeScreen==='function' && (!g.__lastCanvas || g.__lastCanvas.x!==engine.canvasSize.x || g.__lastCanvas.y!==engine.canvasSize.y)) { resizeScreen(new Vec2(engine.canvasSize.x,engine.canvasSize.y)); g.__lastCanvas={x:engine.canvasSize.x,y:engine.canvasSize.y}; }
                const current=input.cursorScreenPosition||{x:0,y:0}, previous=g.__lastCursor||current;
                const event={worldPosition:new Vec3(current.x,current.y,0),localPosition:new Vec2(current.x,current.y)};
                if ((current.x!==previous.x || current.y!==previous.y) && typeof cursorMove==='function') cursorMove(event);
                if (input.cursorLeftDown && !g.__lastLeftDown && typeof cursorDown==='function') cursorDown(event);
                if (!input.cursorLeftDown && g.__lastLeftDown) { if(typeof cursorUp==='function')cursorUp(event); if(typeof cursorClick==='function')cursorClick(event); }
                // Enter/leave are per-layer: hit-test this script's own layer against the cursor.
                if (typeof cursorEnter==='function' || typeof cursorLeave==='function') {
                    const scene=input.cursorScenePosition, origin=thisLayer&&thisLayer.origin, size=thisLayer&&thisLayer.size;
                    if (scene && origin && size) {
                        const halfX=Math.abs(size.x)/2, halfY=Math.abs(size.y)/2;
                        const inside = Math.abs(scene.x-origin.x)<=halfX && Math.abs(scene.y-origin.y)<=halfY;
                        if (inside && !g.__lastInside && typeof cursorEnter==='function') cursorEnter(event);
                        if (!inside && g.__lastInside && typeof cursorLeave==='function') cursorLeave(event);
                        g.__lastInside = inside;
                    }
                }
                Object.keys(__layers).forEach(function(key){let animations=__layers[key].__animations||{};Object.keys(animations).forEach(function(name){if(animations[name].__tick)animations[name].__tick(dt);});});
                g.__lastCursor={x:current.x,y:current.y};g.__lastLeftDown=input.cursorLeftDown;__tickTimers(dt);
            };
        })(this);
        """#

    /// System audio capture; the engine forwards its audio API until the SceneScript runtime takes over.
    let audioCapture: SystemAudioCapture
    /// Per-wallpaper user properties and their music-synced modulation.
    let propertyService: SceneUserPropertyService
    /// Guards the layer states, scene clock and cursor, and the pending structure changes.
    private let levelLock = NSLock()
    private var layerStates: [String: [String: Any]] = [:]
    private var layerAliases: [String: String] = [:]
    private var scriptContexts: [String: JSContext] = [:]
    private var returnFunctions: [String: JSValue] = [:]
    private var initializedScripts = Set<String>()
    private var appliedPropertyRevisions: [String: Int] = [:]
    private var sharedValues: [String: Any] = [:]
    /// Cursor in scene pixels, published by the renderer; `NSEvent.mouseLocation` is screen space
    /// and cannot be hit-tested against layer bounds.
    private var sceneCursorPosition = SIMD2<Float>.zero
    private let scriptLock = NSLock()
    private var sceneDeltaTime: Double = 1.0 / 60.0
    private var sceneFrame: Int = 0
    private var sceneCanvasSize = SIMD2<Double>(1920, 1080)
    /// The layer states the render loop reads between `beginFrame` and `endFrame`. Confined to the
    /// render thread; dictionaries are copy-on-write so taking it is cheap.
    private var frameLayerStates: [String: [String: Any]]?

    private init() {
        _ = BrowserMediaIntegration.shared
        let capture = SystemAudioCapture()
        audioCapture = capture
        propertyService = SceneUserPropertyService(audioLevel: { capture.audioLevel })
    }

    /// Starts capture if Screen Recording was granted since the last check. Never prompts, so it is
    /// safe to call whenever the app activates or the Permissions page appears.
    @MainActor
    func recheckCapturePermission() {
        audioCapture.recheckCapturePermission()
    }

    /// Scene-space cursor for per-layer hit testing; the renderer owns the screen-to-scene mapping.
    func updateSceneCursor(_ position: SIMD2<Float>) {
        levelLock.lock()
        sceneCursorPosition = position
        levelLock.unlock()
    }

    func configureLayers(_ layers: [String: [String: Any]], aliases: [String: String],
                         canvasSize: SIMD2<Float> = SIMD2<Float>(1920, 1080)) {        levelLock.lock()
        layerStates = layers
        layerAliases = aliases
        sceneCanvasSize = SIMD2<Double>(Double(canvasSize.x), Double(canvasSize.y))
        levelLock.unlock()
        scriptLock.lock()
        for context in scriptContexts.values {
            if context.objectForKeyedSubscript("destroy")?.isObject == true {
                _ = context.objectForKeyedSubscript("destroy")?.call(withArguments: [])
            }
        }
        scriptContexts.removeAll()
        returnFunctions.removeAll()
        initializedScripts.removeAll()
        appliedPropertyRevisions.removeAll()
        scriptLock.unlock()
    }

    /// Sets the user properties of one wallpaper instance (keyed by its directory path). With
    /// `replacing`, properties missing from `values` are dropped, so nothing from a previous
    /// configuration of that wallpaper lingers.
    func setUserProperties(_ values: [String: String], wallpaper: String, replacing: Bool) {
        propertyService.setUserProperties(values, wallpaper: wallpaper, replacing: replacing)
    }

    func setSceneClock(deltaTime: Double) {
        levelLock.lock()
        sceneDeltaTime = max(0, min(deltaTime, 0.25))
        sceneFrame &+= 1
        levelLock.unlock()
    }

    // MARK: - Frame snapshot

    /// Bumped whenever any user property changes. Render-side caches key off this to know when
    /// derived GPU state is still valid.
    var propertyRevision: Int { propertyService.propertyRevision }

    /// Starts a frame of `wallpaper` (its directory path): reads until `endFrame` see that
    /// wallpaper's user properties and a snapshot of the layer states, so per-layer reads stop
    /// contending with the audio thread.
    func beginFrame(wallpaper: String) {
        OWEFrameMetrics.countLockAcquisition()
        propertyService.beginFrame(wallpaper: wallpaper)
        levelLock.lock()
        frameLayerStates = layerStates
        levelLock.unlock()
    }

    func endFrame() {
        propertyService.endFrame()
        frameLayerStates = nil
    }

    func userPropertyValue(_ key: String, fallback: Float) -> Float {
        propertyService.userPropertyValue(key, fallback: fallback)
    }

    func isMusicSynced(_ key: String) -> Bool {
        propertyService.isMusicSynced(key)
    }

    // A script that throws does so every frame, so collapse repeats instead of emitting
    // thousands of identical lines and paying the string conversion each time.
    private var scriptExceptionLastLogged: [String: CFAbsoluteTime] = [:]
    private var scriptExceptionCounts: [String: Int] = [:]
    private let scriptExceptionLock = NSLock()

    private func reportScriptException(_ message: String, context: String) {
        let key = "\(context)|\(message)"
        scriptExceptionLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let last = scriptExceptionLastLogged[key]
        let suppressed = scriptExceptionCounts[key] ?? 0
        if let last, now - last < 10 {
            scriptExceptionCounts[key] = suppressed + 1
            scriptExceptionLock.unlock()
            return
        }
        scriptExceptionLastLogged[key] = now
        scriptExceptionCounts[key] = 0
        scriptExceptionLock.unlock()
        if suppressed > 0 {
            OWELog.error(.script, "\(message) [\(context)] (repeated \(suppressed)x)")
        } else {
            OWELog.error(.script, "\(message) [\(context)]")
        }
    }

    func userPropertyString(_ key: String) -> String? {
        propertyService.userPropertyString(key)
    }

    /// One wallpaper instance's property, independent of which wallpaper is being rendered.
    func userPropertyString(_ key: String, wallpaper: String) -> String? {
        propertyService.userPropertyString(key, wallpaper: wallpaper)
    }

    /// Every user property of one wallpaper instance.
    func userProperties(wallpaper: String) -> [String: String] {
        propertyService.userProperties(wallpaper: wallpaper)
    }

    func audioVisualizationSnapshot() -> AudioVisualizationSnapshot {
        audioCapture.audioVisualizationSnapshot()
    }

    func resolveLayerVisibility(_ objects: [WESceneObject], initial: [String: Bool], wallpaper: String) -> [String: Bool] {
        Self.resolveLayerVisibility(objects, initial: initial, userProperties: userProperties(wallpaper: wallpaper))
    }

    static func resolveLayerVisibility(_ objects: [WESceneObject], initial: [String: Bool],
                                       userProperties propertyStrings: [String: String]) -> [String: Bool] {
        var states: [String: [String: Any]] = [:]
        var aliases: [String: String] = [:]
        for (index, object) in objects.enumerated() {
            let id = String(object.id ?? index)
            states[id] = ["name": object.name ?? id, "visible": initial[id] ?? true]
            aliases[id] = id
            aliases[String(index)] = id
            if let name = object.name { aliases[name] = id }
        }
        let userProperties = propertyStrings.mapValues { value -> Any in
            if value.caseInsensitiveCompare("true") == .orderedSame { return true }
            if value.caseInsensitiveCompare("false") == .orderedSame { return false }
            return Double(value) ?? value
        }
        guard let context = JSContext() else { return initial }
        context.exceptionHandler = { _, _ in }
        context.setObject(states, forKeyedSubscript: "__layers" as NSString)
        context.setObject(aliases, forKeyedSubscript: "__layerAliases" as NSString)
        context.setObject(["runtime": 0, "userProperties": userProperties], forKeyedSubscript: "engine" as NSString)
        context.evaluateScript("var console = { log: function() {} }; var thisScene = { getLayerCount: function() { return \(objects.count); }, getLayer: function(layer) { var key = String(layer); return __layers[__layerAliases[key] || key]; } };")

        for (index, object) in objects.enumerated() {
            guard let script = object.visibleScript else { continue }
            let id = String(object.id ?? index)
            guard let layer = context.objectForKeyedSubscript("__layers")?.forProperty(id) else { continue }
            context.setObject(layer, forKeyedSubscript: "thisLayer" as NSString)
            context.evaluateScript(Self.stripESModuleExports(script))
            let fallback = initial[id] ?? false
            _ = context.objectForKeyedSubscript("init")?.call(withArguments: [fallback])
            if let result = context.objectForKeyedSubscript("update")?.call(withArguments: [fallback]), !result.isUndefined {
                layer.setValue(result.toBool(), forProperty: "visible")
            }
        }

        guard let resolved = context.objectForKeyedSubscript("__layers")?.toDictionary() as? [String: Any] else { return initial }
        return initial.merging(resolved.compactMapValues { ($0 as? [String: Any])?["visible"] as? Bool }) { _, value in value }
    }

    func layerValue(_ layerId: String, property: String, fallback: Float) -> Float {
        let components = property.split(separator: ".").map(String.init)
        func resolve(_ states: [String: [String: Any]]) -> Float {
            var current: Any? = states[layerId]
            for component in components {
                current = (current as? [String: Any])?[component]
            }
            return (current as? NSNumber)?.floatValue ?? fallback
        }
        if let frameLayerStates { return resolve(frameLayerStates) }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return resolve(layerStates)
    }

    func layerVector2(_ layerId: String, property: String, fallback: SIMD2<Float>) -> SIMD2<Float> {
        func resolve(_ states: [String: [String: Any]]) -> SIMD2<Float> {
            guard let value = states[layerId]?[property] as? [String: Any],
                  let x = (value["x"] as? NSNumber)?.floatValue,
                  let y = (value["y"] as? NSNumber)?.floatValue else { return fallback }
            return SIMD2<Float>(x, y)
        }
        if let frameLayerStates { return resolve(frameLayerStates) }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return resolve(layerStates)
    }

    func layerBoolean(_ layerId: String, property: String, fallback: Bool) -> Bool {
        func resolve(_ states: [String: [String: Any]]) -> Bool {
            if let value = states[layerId]?[property] as? Bool { return value }
            if let value = states[layerId]?[property] as? NSNumber { return value.boolValue }
            return fallback
        }
        if let frameLayerStates { return resolve(frameLayerStates) }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return resolve(layerStates)
    }

    /// nil when the script has not assigned the property, so callers keep their authored value.
    func layerString(_ layerId: String, property: String) -> String? {
        func resolve(_ states: [String: [String: Any]]) -> String? {
            if let value = states[layerId]?[property] as? String { return value }
            if let value = states[layerId]?[property] as? NSNumber { return value.stringValue }
            return nil
        }
        if let frameLayerStates { return resolve(frameLayerStates) }
        OWEFrameMetrics.countLockAcquisition()
        levelLock.lock()
        defer { levelLock.unlock() }
        return resolve(layerStates)
    }

    /// `thisScene.camerashake` is a scene-wide toggle rather than per-layer state.
    var cameraShakeEnabled: Bool {
        propertyService.globalValue("__camerashake") == 1
    }

    func setLayerVector2(_ layerId: String, property: String, value: SIMD2<Float>) {
        levelLock.lock()
        layerStates[layerId, default: [:]][property] = ["x": value.x, "y": value.y]
        levelLock.unlock()
        frameLayerStates?[layerId, default: [:]][property] = ["x": value.x, "y": value.y]
    }

    func evaluate(_ script: String, fallback: Float, layerId: String? = nil,
                  time: Double = CACurrentMediaTime()) -> Float {
        let value = evaluateValue(script, input: fallback, layerId: layerId, time: time)
        guard let value, value.isNumber else { return fallback }
        let result = value.toDouble()
        return result.isFinite ? Float(result) : fallback
    }

    func evaluateString(_ script: String, fallback: String, layerId: String? = nil,
                        time: Double = CACurrentMediaTime()) -> String {
        evaluateValue(script, input: fallback, layerId: layerId, time: time)?.toString() ?? fallback
    }

    func executeSceneScript(_ script: String, time: Double = CACurrentMediaTime()) {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = evaluateValue(script, input: NSNull(), layerId: nil, time: time)
    }

    func evaluateVector2(_ script: String, fallback: SIMD2<Float>, layerId: String? = nil,
                         time: Double = CACurrentMediaTime()) -> SIMD2<Float>? {
        guard let value = evaluateValue(script, input: [fallback.x, fallback.y], layerId: layerId, time: time) else { return nil }
        if value.isObject,
           let x = value.forProperty("x")?.toNumber(), let y = value.forProperty("y")?.toNumber() {
            return SIMD2<Float>(x.floatValue, y.floatValue)
        }
        if let string = value.toString() {
            let vector = string.parseVector2()
            return SIMD2<Float>(Float(vector.0), Float(vector.1))
        }
        return nil
    }

    func evaluateVector3(_ script: String, fallback: SIMD3<Float>, layerId: String? = nil,
                         time: Double = CACurrentMediaTime()) -> SIMD3<Float>? {
        guard let value = evaluateValue(script, input: [fallback.x, fallback.y, fallback.z], layerId: layerId, time: time) else { return nil }
        if value.isObject,
           let x = value.forProperty("x")?.toNumber(), let y = value.forProperty("y")?.toNumber(),
           let z = value.forProperty("z")?.toNumber() {
            return SIMD3<Float>(x.floatValue, y.floatValue, z.floatValue)
        }
        if let string = value.toString() {
            let vector = string.parseVector3()
            return SIMD3<Float>(Float(vector.0), Float(vector.1), Float(vector.2))
        }
        return nil
    }

    private func evaluateValue(_ script: String, input: Any, layerId: String?, time: Double) -> JSValue? {
        OWEFrameMetrics.countScriptEvaluation()
        let signpost = OWESignpost.begin(OWESignpost.audio, "evaluateScript")
        defer { signpost.end() }
        let contextKey = "\(layerId ?? "global"):\(script)"
        scriptLock.lock()
        let existingContext = scriptContexts[contextKey]
        let context = existingContext ?? JSContext()
        scriptContexts[contextKey] = context
        scriptLock.unlock()
        context?.exceptionHandler = { [weak self] _, exception in
            guard let exception else { return }
            var message = exception.toString() ?? "Unknown JavaScript error"
            var lineNumber: Int?
            if let line = exception.objectForKeyedSubscript("line"), !line.isUndefined {
                lineNumber = Int(line.toInt32())
                message += " (line \(line))"
            }
            if let stack = exception.objectForKeyedSubscript("stack"), !stack.isUndefined,
               let text = stack.toString(), !text.isEmpty {
                message += " stack=[\(text.replacingOccurrences(of: "\n", with: " | "))]"
            }
            // Quote the offending source line. Line numbers come from the evaluated (stripped)
            // source, so resolve against that rather than the original script.
            if let lineNumber, lineNumber > 0 {
                let lines = Self.stripESModuleExports(script).components(separatedBy: .newlines)
                if lineNumber <= lines.count {
                    let text = lines[lineNumber - 1].trimmingCharacters(in: .whitespaces)
                    message += " source=`\(text.prefix(120))`"
                }
            }
            self?.reportScriptException(message, context: contextKey)
        }
        let consoleLog: @convention(block) (String) -> Void = { OWELog.debug(.script, $0) }
        let consoleError: @convention(block) (String) -> Void = { OWELog.error(.script, "ERROR: \($0)") }
        let storageGet: @convention(block) (String, Int) -> String? = { key, scope in
            UserDefaults.standard.string(forKey: "SceneScriptStorage.\(scope).\(key)")
        }
        let storageSet: @convention(block) (String, String, Int) -> Void = { key, value, scope in
            UserDefaults.standard.set(value, forKey: "SceneScriptStorage.\(scope).\(key)")
        }
        let storageDelete: @convention(block) (String, Int) -> Void = { key, scope in
            UserDefaults.standard.removeObject(forKey: "SceneScriptStorage.\(scope).\(key)")
        }
        let storageClear: @convention(block) (Int) -> Void = { scope in
            let prefix = "SceneScriptStorage.\(scope)."
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        context?.setObject(consoleLog, forKeyedSubscript: "__consoleLog" as NSString)
        context?.setObject(consoleError, forKeyedSubscript: "__consoleError" as NSString)
        context?.setObject(storageGet, forKeyedSubscript: "__storageGet" as NSString)
        context?.setObject(storageSet, forKeyedSubscript: "__storageSet" as NSString)
        context?.setObject(storageDelete, forKeyedSubscript: "__storageDelete" as NSString)
        context?.setObject(storageClear, forKeyedSubscript: "__storageClear" as NSString)
        if existingContext == nil {
            context?.setObject(sharedValues, forKeyedSubscript: "shared" as NSString)
            // Wallpaper Engine's own Vec/Mat/colour/math runtime must load first: its `class`
            // declarations cannot shadow the global properties the shim installs, so loading it
            // second throws and defines nothing. Declared first, its lexical bindings win and the
            // shim only fills the gaps.
            if let runtime = Self.wallpaperEngineRuntimeSource {
                context?.evaluateScript(runtime)
            }
            context?.evaluateScript(Self.compatibilityBootstrap)
        }
        let currentLevel = audioLevel
        let currentSpectrum = audioSpectrum
        let visualization = audioVisualizationSnapshot()
        let browser = BrowserMediaIntegration.shared.snapshot()
        let audioBlock: @convention(block) (Double, Double) -> Double = { low, high in
            let minimum = max(0, min(63, Int(low)))
            let maximum = max(minimum, min(63, Int(high)))
            return currentSpectrum[minimum...maximum].max() ?? currentLevel
        }
        let fftBlock: @convention(block) (Double) -> Double = { index in
            currentSpectrum[max(0, min(63, Int(index)))]
        }
        let propertyBlock: @convention(block) (String) -> Double = { [weak self] name in
            self?.propertyService.modulatedValue(name) ?? 0
        }
        let setGlobalBlock: @convention(block) (String, Double) -> Void = { [weak self] name, value in
            self?.propertyService.setGlobalValue(value, forKey: name)
        }
        context?.setObject(audioBlock, forKeyedSubscript: "audio" as NSString)
        context?.setObject(fftBlock, forKeyedSubscript: "fft" as NSString)
        context?.setObject(propertyBlock, forKeyedSubscript: "property" as NSString)
        context?.setObject(setGlobalBlock, forKeyedSubscript: "setGlobal" as NSString)
        context?.setObject(time, forKeyedSubscript: "time" as NSString)
        let cursor = ["x": NSEvent.mouseLocation.x, "y": NSEvent.mouseLocation.y]
        context?.setObject(cursor, forKeyedSubscript: "cursor" as NSString)
        levelLock.lock()
        let scenePoint = sceneCursorPosition
        levelLock.unlock()
        let mouseButtons = NSEvent.pressedMouseButtons
        let modifiers = NSEvent.modifierFlags.rawValue
        levelLock.lock()
        let layers = layerStates
        let aliases = layerAliases
        let deltaTime = sceneDeltaTime
        let canvasSize = sceneCanvasSize
        levelLock.unlock()
        let (modulatedGlobals, userProperties, propertyRevision) = propertyService.scriptInputs()
        context?.setObject(modulatedGlobals, forKeyedSubscript: "global" as NSString)
        context?.setObject(layers, forKeyedSubscript: "__layers" as NSString)
        context?.setObject(aliases, forKeyedSubscript: "__layerAliases" as NSString)
        context?.setObject(sharedValues, forKeyedSubscript: "shared" as NSString)
        let fps = 1.0 / max(deltaTime, 0.0001)
        let screen = NSScreen.main?.frame.size ?? .zero
        context?.setObject([
            "runtime": time, "frametime": deltaTime, "userProperties": userProperties,
            "screenResolution": ["x": screen.width, "y": screen.height],
            "canvasSize": ["x": canvasSize.x, "y": canvasSize.y],
            // Wallpaper Engine reports this as a fraction of the day: scripts compare it against
            // expressions like START_HOUR / 24, so seconds-since-midnight would always saturate.
            "timeOfDay": Double(Calendar.current.component(.hour, from: Date()) * 3600
                + Calendar.current.component(.minute, from: Date()) * 60
                + Calendar.current.component(.second, from: Date())) / 86400.0,
            "AUDIO_RESOLUTION_16": 16, "AUDIO_RESOLUTION_32": 32,
            "AUDIO_RESOLUTION_64": 64, "AUDIO_RESOLUTION_128": 128,
            "audio": visualization.level, "audioLevel": visualization.level,
            "spectrum": visualization.spectrum,
            "waveform": visualization.waveform, "bass": visualization.bass,
            "mid": visualization.mid, "treble": visualization.treble,
            "audioVisualization": [
                "level": visualization.level, "spectrum": visualization.spectrum,
                "waveform": visualization.waveform, "bass": visualization.bass,
                "mid": visualization.mid, "treble": visualization.treble
            ],
            "media": [
                "title": browser.title, "artist": "", "album": "",
                "url": browser.url,
                "duration": 0, "elapsed": 0, "isPlaying": !browser.title.isEmpty
            ]
        ], forKeyedSubscript: "engine" as NSString)
        context?.evaluateScript("""
            engine.registerAsset=function(path){
                var value={__assetPath:String(path||''),name:String(path||''),toString:function(){return this.__assetPath;}};
                engine.__assets=engine.__assets||[]; engine.__assets.push(value); return value;
            };
            engine.registerAudioBuffers=function(resolution){
                var count=(resolution===16||resolution===32||resolution===64)?resolution:64;
                function resample(values){
                    var output=[];
                    for(var i=0;i<count;i++){
                        var start=Math.floor(i*values.length/count), end=Math.max(start+1,Math.floor((i+1)*values.length/count));
                        var sum=0; for(var j=start;j<end;j++) sum+=values[j]||0;
                        output.push(sum/Math.max(1,end-start));
                    }
                    return output;
                }
                var left=resample(engine.spectrum), right=resample(engine.spectrum);
                return new AudioBuffers(left,right);
            };
            engine.setTimeout=setTimeout; engine.setInterval=setInterval;
            """)
        context?.setObject([
            "cursorWorldPosition": ["x": cursor["x"]!, "y": cursor["y"]!],
            "cursorScreenPosition": ["x": cursor["x"]!, "y": cursor["y"]!],
            "cursorScenePosition": ["x": Double(scenePoint.x), "y": Double(scenePoint.y)],
            "cursorLeftDown": (mouseButtons & 1) != 0,
            "cursor": cursor, "mouse": cursor, "buttons": mouseButtons, "modifiers": modifiers,
            "leftDown": (mouseButtons & 1) != 0, "rightDown": (mouseButtons & 2) != 0
        ], forKeyedSubscript: "input" as NSString)
        context?.evaluateScript("""
            Object.keys(__layers).forEach(function(key) { __decorateLayer(__layers[key]); });
            var thisScene = {
                time: \(time), currentTime: \(time), dt: \(deltaTime), fps: \(fps),
                getLayer: function(layer) { var key=String(layer); return __decorateLayer(__layers[__layerAliases[key] || key]); },
                getLayerByID: function(id) { return this.getLayer(id); },
                getLayerCount: function() { return Object.keys(__layers).length; },
                enumerateLayers: function() { return Object.keys(__layers).map(key => __decorateLayer(__layers[key])); },
                getLayerIndex: function(layer) { return Object.keys(__layers).indexOf(String(layer && layer.id !== undefined ? layer.id : (__layerAliases[String(layer)] || layer))); },
                getInitialLayerConfig: function(layer) { var value=this.getLayer(layer); return value ? JSON.parse(JSON.stringify(value)) : null; },
                createLayer: function(model) {
                    var sourceId = (typeof thisLayer !== 'undefined' && thisLayer && thisLayer.id !== undefined) ? String(thisLayer.id) : Object.keys(__layers)[0];
                    var asset = (model && model.__assetPath) ? String(model.__assetPath) : String(model || '');
                    var source = __layers[sourceId];
                    if (!source) return null;
                    var id = '__clone_' + sourceId + '_' + (__pendingLayerCreations.length + Object.keys(__layers).length);
                    var clone = JSON.parse(JSON.stringify(source));
                    clone.id = id;
                    clone.name = id;
                    __layers[id] = clone;
                    __pendingLayerCreations.push({ id: id, source: sourceId, model: asset });
                    return __decorateLayer(clone);
                },
                destroyLayer: function(layer) {
                    var id = String(layer && layer.id !== undefined ? layer.id : layer);
                    if (!__layers[id]) return false;
                    delete __layers[id];
                    __pendingLayerRemovals.push(id);
                    return true;
                },
                sortLayer: function(layer, index) {
                    var id = String(layer && layer.id !== undefined ? layer.id : layer);
                    __pendingLayerOrder.push({ id: id, index: Number(index) || 0 });
                }
            };
            // thisScene is rebuilt every frame, so scene-wide state lives on globals behind
            // accessors instead of on the object itself.
            this.__camera = this.__camera || { position: new Vec3(0,0,0), zoom: 1, fov: 45 };
            Object.defineProperty(thisScene, 'camerashake', {
                get: function(){ return __camerashake === 1; },
                set: function(v){ __camerashake = v ? 1 : 0; }
            });
            Object.defineProperty(thisScene, 'camera', {
                get: function(){ return __camera; },
                set: function(v){ if (v) __camera = v; }
            });
            """)
        let layer = layerId.flatMap { layers[$0] } ?? ["value": input]
        context?.setObject(layer, forKeyedSubscript: "thisLayer" as NSString)
        context?.evaluateScript("thisLayer = __decorateLayer(thisLayer); var thisObject = thisLayer;")
        if let properties = layer["scriptProperties"] as? [String: String] {
            let converted = properties.mapValues { value -> Any in
                if value.caseInsensitiveCompare("true") == .orderedSame { return true }
                if value.caseInsensitiveCompare("false") == .orderedSame { return false }
                return Double(value) ?? value
            }
            context?.setObject(converted, forKeyedSubscript: "__scriptProperties" as NSString)
        }
        let value: JSValue?
        scriptLock.lock()
        let needsInitialization = !initializedScripts.contains(contextKey)
        if needsInitialization { initializedScripts.insert(contextKey) }
        scriptLock.unlock()
        let moduleSource = Self.stripESModuleExports(script)
        let result = needsInitialization ? context?.evaluateScript(moduleSource) : nil
        // Scripts receive vector properties as Vec2/Vec3 and mutate them in place (`value.z = ...`).
        // A bridged Swift array is read-only in JS, so strict-mode scripts throw on assignment.
        let scriptInput = Self.vectorInput(input, in: context) ?? input
        if needsInitialization, context?.objectForKeyedSubscript("init")?.isObject == true {
            _ = context?.objectForKeyedSubscript("init")?.call(withArguments: [scriptInput])
        }
        scriptLock.lock()
        let appliedRevision = appliedPropertyRevisions[contextKey] ?? -1
        if appliedRevision != propertyRevision { appliedPropertyRevisions[contextKey] = propertyRevision }
        scriptLock.unlock()
        if appliedRevision != propertyRevision,
           context?.objectForKeyedSubscript("applyUserProperties")?.isObject == true {
            _ = context?.objectForKeyedSubscript("applyUserProperties")?.call(withArguments: [userProperties])
        }
        context?.evaluateScript("__dispatchRuntimeEvents(\(deltaTime));")
        if context?.objectForKeyedSubscript("update")?.isObject == true {
            value = context?.objectForKeyedSubscript("update")?.call(withArguments: [scriptInput])
        } else if script.contains("return") {
            let function: JSValue?
            scriptLock.lock()
            function = returnFunctions[contextKey]
            scriptLock.unlock()
            if let function {
                value = function.call(withArguments: [scriptInput])
            } else {
                let compiled = context?.evaluateScript("(function(value) { \(moduleSource) })")
                if let compiled {
                    scriptLock.lock()
                    returnFunctions[contextKey] = compiled
                    scriptLock.unlock()
                }
                value = compiled?.call(withArguments: [scriptInput])
            }
        } else {
            value = result
        }
        if let dictionary = context?.objectForKeyedSubscript("__layers")?.toDictionary() as? [String: Any] {
            let updatedLayers = dictionary.compactMapValues { $0 as? [String: Any] }
            levelLock.lock()
            layerStates = updatedLayers
            levelLock.unlock()
            // Scripts mutate layer state mid-frame; keep the snapshot coherent for later layers.
            if frameLayerStates != nil { frameLayerStates = updatedLayers }
        }
        if let dictionary = context?.objectForKeyedSubscript("shared")?.toDictionary() as? [String: Any] {
            scriptLock.lock()
            sharedValues = dictionary
            scriptLock.unlock()
        }
        if let creations = context?.objectForKeyedSubscript("__pendingLayerCreations")?.toArray() as? [[String: Any]],
           !creations.isEmpty {
            levelLock.lock()
            pendingLayerCreations.append(contentsOf: creations)
            levelLock.unlock()
            context?.evaluateScript("__pendingLayerCreations.length = 0;")
        }
        if let ordering = context?.objectForKeyedSubscript("__pendingLayerOrder")?.toArray() as? [[String: Any]],
           !ordering.isEmpty {
            levelLock.lock()
            pendingLayerOrder.append(contentsOf: ordering)
            levelLock.unlock()
            context?.evaluateScript("__pendingLayerOrder.length = 0;")
        }
        if let removals = context?.objectForKeyedSubscript("__pendingLayerRemovals")?.toArray() as? [String],
           !removals.isEmpty {
            levelLock.lock()
            pendingLayerRemovals.append(contentsOf: removals)
            levelLock.unlock()
            context?.evaluateScript("__pendingLayerRemovals.length = 0;")
        }
        if let shake = context?.objectForKeyedSubscript("__camerashake"), !shake.isUndefined {
            let value = Double(shake.toInt32())
            propertyService.setGlobalValue(value, forKey: "__camerashake", includingFrame: true)
        }
        return value
    }

    /// Layers requested by `thisScene.createLayer`, consumed once by the renderer.
    private var pendingLayerCreations: [[String: Any]] = []
    private var pendingLayerOrder: [[String: Any]] = []
    private var pendingLayerRemovals: [String] = []

    func drainPendingLayerRemovals() -> [String] {
        levelLock.lock()
        let pending = pendingLayerRemovals
        pendingLayerRemovals.removeAll(keepingCapacity: true)
        levelLock.unlock()
        return pending
    }

    func drainPendingLayerCreations() -> [(id: String, source: String)] {
        levelLock.lock()
        let pending = pendingLayerCreations
        pendingLayerCreations.removeAll(keepingCapacity: true)
        levelLock.unlock()
        return pending.compactMap { entry in
            guard let id = entry["id"] as? String, let source = entry["source"] as? String else { return nil }
            return (id, source)
        }
    }

    func drainPendingLayerOrder() -> [(id: String, index: Int)] {
        levelLock.lock()
        let pending = pendingLayerOrder
        pendingLayerOrder.removeAll(keepingCapacity: true)
        levelLock.unlock()
        return pending.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let index = (entry["index"] as? NSNumber)?.intValue ?? 0
            return (id, index)
        }
    }

    var audioLevel: Double {
        if let level = propertyService.frameAudioLevel { return level }
        OWEFrameMetrics.countLockAcquisition()
        return audioCapture.audioLevel
    }

    private var audioSpectrum: [Double] { audioCapture.audioSpectrum }

    /// The latest smoothed WE spectra, without advancing the smoothing. (`audioSpectrum` is
    /// already the legacy 64-band mono array used by the script bindings.)
    var audioSpectrumSnapshot: AudioSpectrumSnapshot { audioCapture.audioSpectrumSnapshot }

    /// Advances the spectrum smoothing by one frame. The renderer calls this exactly once per
    /// rendered frame and binds the result to every pass of that frame.
    func advanceAudioSpectrumFrame() -> AudioSpectrumSnapshot { audioCapture.advanceAudioSpectrumFrame() }
}
