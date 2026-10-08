import Foundation

/// Small SceneScript compatibility surface, intentionally limited to the APIs used by
/// the supported scene. Each property has a lexical scope; layers/shared are per scene.
enum SceneScriptBootstrap {
    static let source = #"""
    class Vec3 {
      constructor(x=0,y=x,z=x) { if(typeof x==='object') {this.x=x.x;this.y=x.y;this.z=x.z||0;} else {this.x=x;this.y=y;this.z=z;} }
      copy(){return new Vec3(this.x,this.y,this.z);}
      add(v){return new Vec3(this.x+v.x,this.y+v.y,this.z+(v.z||0));}
      subtract(v){return new Vec3(this.x-v.x,this.y-v.y,this.z-(v.z||0));}
      multiply(v){return typeof v==='number'?new Vec3(this.x*v,this.y*v,this.z*v):new Vec3(this.x*v.x,this.y*v.y,this.z*v.z);}
      divide(v){return new Vec3(this.x/v,this.y/v,this.z/v);}
      length(){return Math.hypot(this.x,this.y,this.z);}
      normalize(){const n=this.length();return n?this.divide(n):this.copy();}
    }
    class Vec2 extends Vec3 { constructor(x=0,y=x){super(x,y,0);} }
    const WEMath={mix:(a,b,t)=>a+(b-a)*t,clamp:(x,a,b)=>Math.max(a,Math.min(b,x)),
      smoothStep:(a,b,x)=>{let t=Math.max(0,Math.min(1,(x-a)/(b-a)));return t*t*(3-2*t);}};
    const shared={}, input={cursorWorldPosition:new Vec3(-1e6)}, layers=[], scripts=[], bindings=[];
    const audioBuffers=[];
    const engine={runtime:0,frametime:0,canvasSize:new Vec2(),AUDIO_RESOLUTION_16:16,AUDIO_RESOLUTION_32:32,AUDIO_RESOLUTION_64:64,
      openUserShortcut:key=>nativeShortcut(String(key)),registerAudioBuffers:n=>{if(![16,32,64].includes(n))throw Error('Unsupported audio resolution');const b={left:Array(n).fill(0),right:Array(n).fill(0),average:Array(n).fill(0)};audioBuffers.push(b);return b;}};
    const console={log:x=>nativeLog(String(x)),warn:x=>nativeLog(String(x)),error:x=>nativeLog(String(x))};
    const thisScene={getLayer:key=>layers.find(l=>l.name===key||l.id===key),getLayerIndex:l=>layers.indexOf(l)};
    const localStorage={get:key=>revive(JSON.parse(nativeRead(String(key))||'null')),set:(key,v)=>nativeWrite(String(key),JSON.stringify(v))};
    function revive(v){if(v&&typeof v==='object'&&'x'in v&&'y'in v)return new Vec3(v);return v;}
    function vector(v){if(typeof v==='string')return new Vec3(...v.trim().split(/\s+/).map(Number));return revive(v);}
    let userProperties={};
    function resolve(v){if(v&&typeof v==='object'&&!Array.isArray(v)&&'value'in v){if(typeof v.user==='string'&&v.user in userProperties)return resolve(userProperties[v.user]);return resolve(v.value);}return v;}
    const vectorKeys=new Set(['origin','scale','angles','size','color']);
    function typed(k,v){return vectorKeys.has(k)?(typeof v==='number'?new Vec3(v):vector(v)):v;}
    function createScriptProperties(){const values={};const b={finish:()=>values};for(const name of ['addSlider','addCheckbox','addCombo','addText','addColor','addFile','addDirectory'])b[name]=p=>{values[p.name]=p.value===undefined?(p.options||[{}])[0].value:p.value;return b;};return b;}
    function invoke(s,event,arg){if(s.failed||!s.events[event])return;try{return s.events[event](arg);}catch(e){s.failed=true;nativeLog(s.label+' '+event+': '+e.stack);}}
    function assign(s,value){if(value!==undefined)s.owner[s.key]=typed(s.key,value);}
    function configure(s){if(s.events.properties)for(const k of Object.keys(s.config))s.events.properties[k]=resolve(s.config[k]);}
    function loadScene(raw,properties,width,height){
      userProperties=properties;engine.canvasSize=new Vec2(width,height);
      for(const o of raw){const l={id:o.id,name:o.name||'',origin:new Vec3(),scale:new Vec3(1),angles:new Vec3(),size:new Vec2(128),visible:true,alpha:1};
        for(const k of Object.keys(o))if(k!=='effects')l[k]=typed(k,resolve(o[k]));
        l.getParent=()=>layers.find(p=>p.id===o.parent)||null; layers.push(l);}
      function walk(raw,owner,layer,path){for(const k of Object.keys(raw)){
        const v=raw[k];if(v&&typeof v==='object'&&!Array.isArray(v)&&'value'in v){
          owner[k]=typed(k,resolve(v));if(v.user)bindings.push({raw:v,owner,key:k});
          if(typeof v.script==='string'){
            const s={owner,key:k,layer,config:v.scriptproperties||{},label:layer.name+'.'+path+k,failed:false};
            try{
              // Only WE's built-in WEMath import is supported; reject other modules explicitly.
              let code=v.script.replace(/import\s+\*\s+as\s+WEMath\s+from\s+['"]WEMath['"]\s*;?/g,'');
              if(/\bimport\s/.test(code))throw Error('Unsupported SceneScript import');
              code=code.replace(/\bexport\s+(?=(?:function|let|var|const)\b)/g,'');
              const names=['init','update','destroy','applyUserProperties','cursorDown','cursorUp','cursorClick','cursorMove','cursorEnter','cursorLeave'];
              const ret=names.map(n=>n+':typeof '+n+"==='function'?"+n+':undefined').join(',');
              s.events=new Function('thisLayer',code+'\nreturn {'+ret+",properties:typeof scriptProperties==='undefined'?null:scriptProperties};")(layer);
              configure(s);scripts.push(s);
            }catch(e){nativeLog(s.label+': '+e);}
          }
        }else if(v&&typeof v==='object'){
          owner[k]=Array.isArray(v)?[]:{};walk(v,owner[k],layer,path+k+'.');
        }else { owner[k]=typed(k,v); }
      }}
      raw.forEach((o,i)=>walk(o,layers[i],layers[i],''));
      for(const s of scripts)assign(s,invoke(s,'init',s.owner[s.key]));
      for(const s of scripts)invoke(s,'applyUserProperties',userProperties);
    }
    function applyProperties(changed){Object.assign(userProperties,changed);for(const b of bindings)if(b.raw.user in changed)b.owner[b.key]=typed(b.key,resolve(b.raw));for(const s of scripts){configure(s);invoke(s,'applyUserProperties',changed);}}
    function tick(dt,x,y){engine.frametime=dt;engine.runtime+=dt;input.cursorWorldPosition=new Vec3(x,y,0);for(const s of scripts)assign(s,invoke(s,'update',s.owner[s.key]));}
    function cursorEvent(name,id,x,y){const e={worldPosition:new Vec3(x,y,0),localPosition:new Vec3(x,y,0)};for(const s of scripts)if(s.layer.id===id)invoke(s,name,e);}
    function setSpectrum(left,right){for(const b of audioBuffers)for(let i=0;i<b.average.length;i++){const j=Math.floor(i*left.length/b.average.length);b.left[i]=left[j]||0;b.right[i]=right[j]||0;b.average[i]=(b.left[i]+b.right[i])/2;}}
    function shutdown(){for(const s of scripts)invoke(s,'destroy');scripts.length=0;layers.length=0;bindings.length=0;audioBuffers.length=0;}
    """#
}

/// Property-list backed overrides never modify the workshop's project.json.
/// The notification carries the directory identity so every matching screen updates.
final class ScenePropertyStore {
    static let shared = ScenePropertyStore()
    static let didChange = Notification.Name("ScenePropertiesDidChange")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ directory: URL) -> String { "SceneProperties." + directory.standardizedFileURL.path }

    func definitions(at directory: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("project.json")),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = project["general"] as? [String: Any] else { return [:] }
        return general["properties"] as? [String: [String: Any]] ?? [:]
    }
    func values(at directory: URL) -> [String: Any] {
        let definitions = definitions(at: directory)
        var values = definitions.compactMapValues { $0["value"] }
        for (name, value) in defaults.dictionary(forKey: key(directory)) ?? [:] {
            if let definition = definitions[name], let valid = validated(value, definition: definition) { values[name] = valid }
        }
        return values
    }
    func set(_ value: Any, name: String, at directory: URL) {
        guard let definition = definitions(at: directory)[name], let value = validated(value, definition: definition) else { return }
        var saved = defaults.dictionary(forKey: key(directory)) ?? [:]
        saved[name] = value
        defaults.set(saved, forKey: key(directory))
        notify(directory, changes: [name: value])
    }
    func reset(at directory: URL) {
        defaults.removeObject(forKey: key(directory))
        notify(directory, changes: values(at: directory))
    }
    private func notify(_ directory: URL, changes: [String: Any]) {
        NotificationCenter.default.post(name: Self.didChange, object: directory.standardizedFileURL.path, userInfo: changes)
    }
    private func validated(_ value: Any, definition: [String: Any]) -> Any? {
        switch definition["type"] as? String {
        case "bool": return (value as? NSNumber)?.boolValue
        case "slider":
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
            let low = (definition["min"] as? NSNumber)?.doubleValue ?? 0
            let high = max(low, (definition["max"] as? NSNumber)?.doubleValue ?? 1)
            let step = (definition["step"] as? NSNumber)?.doubleValue ?? ((definition["fraction"] as? Bool == true) ? 0.01 : 1)
            let clamped = min(high, max(low, number.doubleValue))
            return step > 0 ? min(high, max(low, low + ((clamped-low)/step).rounded()*step)) : clamped
        case "color":
            guard let text = value as? String else { return nil }
            let rgb = text.split(separator: " ").compactMap { Double($0) }
            guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            return text
        case "combo":
            let options = definition["options"] as? [[String: Any]] ?? []
            return options.contains { String(describing: $0["value"] ?? "") == String(describing: value) } ? value : nil
        default: return value as? String
        }
    }

    /// Accept only property comparisons and boolean operators, never executable JS.
    static func isVisible(_ definition: [String: Any], values: [String: Any]) -> Bool {
        guard let condition = definition["condition"] as? String, !condition.isEmpty else { return true }
        return condition.components(separatedBy: "||").contains { alternative in
            alternative.components(separatedBy: "&&").allSatisfy { term in
                let pattern = #"^\s*([A-Za-z_][A-Za-z_0-9]*)\.value\s*(==|!=|>=|<=|>|<)\s*(true|false|-?[0-9]+(?:\.[0-9]+)?|'[^']*'|"[^"]*")\s*$"#
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: term, range: NSRange(term.startIndex..., in: term)) else { return false }
                func group(_ i: Int) -> String { String(term[Range(match.range(at: i), in: term)!]) }
                guard let actual = values[group(1)] else { return false }
                let op = group(2), literal = group(3)
                let expected: String = literal == "true" ? "1" : literal == "false" ? "0" : literal.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let text = (actual as? NSNumber)?.stringValue ?? String(describing: actual)
                if op == "==" { return text == expected }
                if op == "!=" { return text != expected }
                guard let a = Double(text), let b = Double(expected) else { return false }
                switch op { case ">": return a > b; case "<": return a < b; case ">=": return a >= b; default: return a <= b }
            }
        }
    }
}
