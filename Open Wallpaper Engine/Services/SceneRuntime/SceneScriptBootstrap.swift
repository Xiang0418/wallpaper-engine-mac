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
