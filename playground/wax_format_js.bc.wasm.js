(function(a){typeof
globalThis!=="object"&&(this?b():(a.defineProperty(a.prototype,"_T_",{configurable:!0,get:b}),_T_));function
b(){var
b=this||self;b.globalThis=b;delete
a.prototype._T_}}(Object));(am=>async a=>{"use strict";const{link:p,src:aj,generated:W,enable_jspi:D,native_effects:ae}=a,g=globalThis.process?.versions?.node,ad={cos:Math.cos,sin:Math.sin,tan:Math.tan,acos:Math.acos,asin:Math.asin,atan:Math.atan,cosh:Math.cosh,sinh:Math.sinh,tanh:Math.tanh,acosh:Math.acosh,asinh:Math.asinh,atanh:Math.atanh,cbrt:Math.cbrt,exp:Math.exp,expm1:Math.expm1,log:Math.log,log1p:Math.log1p,log2:Math.log2,log10:Math.log10,atan2:Math.atan2,hypot:Math.hypot,pow:Math.pow,fmod:(a,b)=>a%b},J=[Float32Array,Float64Array,Int8Array,Uint8Array,Int16Array,Uint16Array,Int32Array,Int32Array,Int32Array,Int32Array,Float32Array,Float64Array,Uint8Array,Uint16Array,Uint8ClampedArray],f=g&&require("node:fs"),q=g&&globalThis.process.platform==="win32",i=new
Map(),m=new
Set(),n=new
Map();let
af=1000000;const
k=q?a=>a.replaceAll("\\","/"):a=>a,T=q?a=>{const
b=/^(?:[\\/]{2}[.?][\\/])?(CON|CONIN\$|CONOUT\$)$/i.exec(a);return b?`\\\\.\\${b[1].toUpperCase()}`:a}:a=>a;function
H(a,b){a=k(a);i.set(a,b);let
c=a;while(!0){const
a=c.lastIndexOf("/");if(a<=0)break;c=c.slice(0,a);m.add(c)}}if(a.files)for(const[c,b]of
Object.entries(a.files))H(c,Uint8Array.from(atob(b),a=>a.charCodeAt(0)));const
b=f?.constants,K=f?[b.R_OK,b.W_OK,b.X_OK,b.F_OK]:[],ah=f?[b.O_RDONLY,b.O_WRONLY,b.O_RDWR,b.O_APPEND,b.O_CREAT,b.O_TRUNC,b.O_EXCL,b.O_NONBLOCK,b.O_NOCTTY,b.O_DSYNC,b.O_SYNC]:[];var
h={map:new
WeakMap(),set:new
Set(),finalization:new
FinalizationRegistry(a=>h.set.delete(a))};function
ai(a){const
b=new
WeakRef(a);h.map.set(a,b);h.set.add(b);h.finalization.register(a,b,a)}function
ak(a){const
b=h.map.get(a);if(b){h.map.delete(a);h.set.delete(b);h.finalization.unregister(a)}}function
S(){return[...h.set].map(a=>a.deref()).filter(a=>a)}var
I;function
ac(a){return D&&WebAssembly?.Suspending?new
WebAssembly.Suspending(a):a}function
G(a){return D&&WebAssembly?.promising&&a?WebAssembly.promising(a):a}const
l=new
TextDecoder("utf-8",{ignoreBOM:1}),U=new
TextEncoder();var
w=new
Uint8Array(0);function
x(){if(w.byteLength===0)w=new
Uint8Array(N.buffer,0,O.value);return w}function
o(a,b){b=Math.imul(b,0xcc9e2d51|0);b=b<<15|b>>>17;b=Math.imul(b,0x1b873593);a^=b;a=a<<13|a>>>19;return(a+(a<<2)|0)+(0xe6546b64|0)|0}function
$(a){for(var
b=0;b<a.length;b++)if(a.charCodeAt(b)>0xff)return!1;return!0}function
Q(a,b){var
e=b.length,c,d;for(c=0;c+4<=e;c+=4){d=b.charCodeAt(c)|b.charCodeAt(c+1)<<8|b.charCodeAt(c+2)<<16|b.charCodeAt(c+3)<<24;a=o(a,d)}d=0;switch(e&3){case
3:d=b.charCodeAt(c+2)<<16;case
2:d|=b.charCodeAt(c+1)<<8;case
1:d|=b.charCodeAt(c);a=o(a,d)}return a^e}function
X(a,b){if($(b))return Q(a,b);var
d=b.length,c,e;for(c=0;c+2<=d;c+=2){e=b.charCodeAt(c)|b.charCodeAt(c+1)<<16;a=o(a,e)}if(d&1)a=o(a,b.charCodeAt(c));return a^d}function
F(a){return g&&globalThis.process.env[a]!==undefined?globalThis.process.env[a]:globalThis.jsoo_env?.[a]}let
s=0;for(const
a
of
F("OCAMLRUNPARAM")?.split(",")||[]){if(a==="b")s=1;if(a.startsWith("b="))s=+a.slice(2)?1:0}function
u(a,b){var
c;if(a.isFile())c=0;else if(a.isDirectory())c=1;else if(a.isCharacterDevice())c=2;else if(a.isBlockDevice())c=3;else if(a.isSymbolicLink())c=4;else if(a.isFIFO())c=5;else if(a.isSocket())c=6;return M(b,a.dev,a.ino|0,c,a.mode&0o7777,a.nlink,a.uid,a.gid,a.rdev,BigInt(a.size),a.atimeMs/1000,a.mtimeMs/1000,a.ctimeMs/1000)}const
ag=globalThis.process?.arch==="arm64",_=new
Error().stack?.includes("\n    at ")??!1,d=Function.prototype.call,c=DataView.prototype;function
j(a,b,c,d){if(!ae)return B(a,b,c,d);const
e=v.value;v.value=0;try{return B(a,b,c,d)}finally{v.value=e}}const
L={jstag:WebAssembly.JSTag||new
WebAssembly.Tag({parameters:["externref"],results:[]}),identity:a=>a,from_bool:a=>!!a,get:(a,b)=>a[b],set:(a,b,c)=>a[b]=c,delete:(a,b)=>delete
a[b],instanceof:(a,b)=>a
instanceof
b,is_js_error:a=>a
instanceof
Error,to_js_string:a=>String(a),typeof:a=>typeof
a,equals:(a,b)=>a==b,strict_equals:(a,b)=>a===b,fun_call:(a,b,c)=>a.apply(b,c),meth_call:(a,b,c)=>a[b].apply(a,c),new_array:a=>new
Array(a),new_obj:()=>({}),new:(a,b)=>new
a(...b),global_this:globalThis,iter_props:(a,b)=>{for(var
c
in
a)if(Object.hasOwn(a,c))b(c)},array_length:a=>a.length,array_get:(a,b)=>a[b],array_set:(a,b,c)=>a[b]=c,read_string:a=>l.decode(x().subarray(0,a)),read_string_stream:(a,b)=>l.decode(x().subarray(0,a),{stream:b}),append_string:(a,b)=>a+b,write_string:a=>{var
c=0,b=a.length;for(;;){const{read:d,written:e}=U.encodeInto(a.slice(c),x());b-=d;if(!b)return e;P(e);c+=d}},ta_create:(a,b)=>new
J[a](b),ta_normalize:a=>a
instanceof
Uint32Array?new
Int32Array(a.buffer,a.byteOffset,a.length):a,ta_kind:b=>J.findIndex(a=>b
instanceof
a),ta_length:a=>a.length,ta_get_i32:(a,b)=>a[b],ta_fill:(a,b)=>a.fill(b),ta_blit:(a,b)=>b.set(a),ta_subarray:(a,b,c)=>a.subarray(b,c),ta_set:(a,b,c)=>a.set(b,c),ta_new:a=>new
Uint8Array(a),ta_copy:(a,b,c,d)=>a.copyWithin(b,c,d),ta_bytes:a=>new
Uint8Array(a.buffer,a.byteOffset,a.length*a.BYTES_PER_ELEMENT),dv_make:a=>new
DataView(a.buffer,a.byteOffset,a.byteLength),dv_get_f64:d.bind(c.getFloat64),dv_get_f32:d.bind(c.getFloat32),dv_get_i64:d.bind(c.getBigInt64),dv_get_i32:_?d.bind(c.getInt32):(a,b,c)=>a.getInt32(b,c),dv_get_i16:d.bind(c.getInt16),dv_get_ui16:d.bind(c.getUint16),dv_get_i8:d.bind(c.getInt8),dv_get_ui8:d.bind(c.getUint8),dv_set_f64:d.bind(c.setFloat64),dv_set_f32:d.bind(c.setFloat32),dv_set_i64:d.bind(c.setBigInt64),dv_set_i32:d.bind(c.setInt32),dv_set_i16:d.bind(c.setInt16),dv_set_i8:d.bind(c.setInt8),littleEndian:new
Uint8Array(new
Uint32Array([1]).buffer)[0],wrap_callback:b=>function(...a){if(a.length===0)a=[undefined];return j(b,a.length,a,1)},wrap_callback_args:b=>function(...a){return j(b,1,[a],0)},wrap_callback_strict:(c,b)=>function(...a){a.length=c;return j(b,c,a,0)},wrap_callback_unsafe:b=>function(...a){return j(b,a.length,a,2)},wrap_meth_callback:b=>function(...a){a.unshift(this);return j(b,a.length,a,1)},wrap_meth_callback_args:b=>function(...a){return j(b,2,[this,a],0)},wrap_meth_callback_strict:(c,b)=>function(...a){a.length=c;a.unshift(this);return j(b,a.length,a,0)},wrap_meth_callback_unsafe:b=>function(...a){a.unshift(this);return j(b,a.length,a,2)},wrap_fun_arguments:b=>function(...a){return b(a)},format_float:(a,b,c,d)=>{function
m(a){var
b=new
DataView(new
ArrayBuffer(8));b.setFloat64(0,a);var
d=b.getUint32(0),f=b.getUint32(4),c=d>>>20&0x7ff,e=BigInt(d&0xfffff)<<32n|BigInt(f);return c===0?[e,-1074]:[e|1n<<52n,c-1075]}function
k(a,b){var
d=m(a),e=d[0],c=1n;if(b>=0)e*=10n**BigInt(b);else
c=10n**BigInt(-b);if(d[1]>=0)e<<=BigInt(d[1]);else
c<<=BigInt(-d[1]);var
f=e/c,g=e%c*2n;if(g>c||g===c&&f&1n)f+=1n;return f}function
o(a,b){var
c=k(a,b).toString();if(b===0)return c;if(c.length<=b)c="0".repeat(b+1-c.length)+c;return c.slice(0,c.length-b)+"."+c.slice(c.length-b)}function
n(a,b){if(a===0)return(b>0?"0."+"0".repeat(b):"0")+"e+0";var
d=Math.floor(Math.log10(a));for(;;){var
c=k(a,b-d).toString();if(c.length===b+1){var
e=b>0?c.charAt(0)+"."+c.slice(1):c;return e+"e"+(d<0?"-":"+")+Math.abs(d)}d+=c.length-(b+1)}}function
l(a,b){return b>100?n(a,b):a.toExponential(b)}function
j(a,b){return b>100||a>=1e21?o(a,b):a.toFixed(b)}switch(b){case
0:var
e=l(d,a),f=e.length;if(e.charAt(f-3)==="e")e=e.slice(0,f-1)+"0"+e.slice(f-1);break;case
1:e=j(d,a);break;case
2:a=a?a:1;e=l(d,a-1);var
i=e.indexOf("e"),h=+e.slice(i+1);if(h<-4||d>=1e21||d.toFixed(0).length>a){var
f=i-1;while(e.charAt(f)==="0")f--;if(e.charAt(f)===".")f--;e=e.slice(0,f+1)+e.slice(i);f=e.length;if(e.charAt(f-3)==="e")e=e.slice(0,f-1)+"0"+e.slice(f-1);break}else{var
g=a;if(h<0){g-=h+1;e=j(d,g)}else
while(e=j(d,g),e.length>a+1)g--;if(g){var
f=e.length-1;while(e.charAt(f)==="0")f--;if(e.charAt(f)===".")f--;e=e.slice(0,f+1)}}break}return c?" "+e:e},gettimeofday:()=>Date.now()/1000,times:()=>{if(globalThis.process?.cpuUsage){var
a=globalThis.process.cpuUsage();return z(a.user/1e6,a.system/1e6)}else{var
a=performance.now()/1000;return z(a,0)}},gmtime:a=>{var
b=new
Date(a*1000),c=b.getTime(),e=new
Date(Date.UTC(b.getUTCFullYear(),0,1)).getTime(),d=Math.floor((c-e)/86400000);return A(b.getUTCSeconds(),b.getUTCMinutes(),b.getUTCHours(),b.getUTCDate(),b.getUTCMonth(),b.getUTCFullYear()-1900,b.getUTCDay(),d,!1)},localtime:a=>{var
b=new
Date(a*1000),g=Math.floor((Date.UTC(b.getFullYear(),b.getMonth(),b.getDate())-Date.UTC(b.getFullYear(),0,1))/86400000),d=new
Date(b.getFullYear(),0,1),e=new
Date(b.getFullYear(),6,1),f=Math.max(d.getTimezoneOffset(),e.getTimezoneOffset()),c=b.getTimezoneOffset()<f;if(f===0&&d.getTimezoneOffset()!==e.getTimezoneOffset()&&globalThis.Intl?.DateTimeFormat?.().resolvedOptions().timeZone==="Europe/Dublin")c=!c;return A(b.getSeconds(),b.getMinutes(),b.getHours(),b.getDate(),b.getMonth(),b.getFullYear()-1900,b.getDay(),g,c)},mktime:(a,b,c,d,e,f)=>new
Date(a,b,c,d,e,f).getTime(),random_seed:()=>crypto.getRandomValues(new
Int32Array(12)),access:(a,d)=>f.accessSync(a,K.reduce((a,b,c)=>d&1<<c?a|b:a,0)),open:(a,d,c)=>{const
b=k(a);if(i.has(b)&&!(d&2)){const
a=af++;n.set(a,{data:i.get(b),offset:0});return a}return f.openSync(T(a),ah.reduce((a,b,c)=>d&1<<c?a|b:a,0),c)},close:a=>{if(n.has(a)){n.delete(a);return}f.closeSync(a)},write:(a,b,c,d,e)=>f?f.writeSync(a,b,c,d,e===null?e:Number(e)):(console[a===2?"error":"log"](typeof
b==="string"?b:l.decode(b.slice(c,c+d))),d),read:(a,b,c,d,e)=>{const
g=n.get(a);if(g){const
f=e===null?g.offset:Number(e),a=Math.min(d,g.data.length-f);if(a<=0)return 0;b.set(g.data.subarray(f,f+a),c);g.offset=f+a;return a}return f.readSync(a,b,c,d,e)},fsync:a=>f.fsyncSync(a),file_size:a=>{const
b=n.get(a);return b?BigInt(b.data.length):f.fstatSync(a,{bigint:!0}).size},register_channel:ai,unregister_channel:ak,channel_list:S,exit:a=>g&&globalThis.process.exit(a),argv:()=>g?globalThis.process.argv.slice(1):["a.out"],on_windows:+q,on_arm64:+ag,getenv:F,backtrace_status:()=>s,record_backtrace:a=>s=a,system:a=>{var
b=require("node:child_process").spawnSync(a,{shell:!0,stdio:"inherit"});if(b.error)throw b.error;return b.signal?255:b.status},isatty:a=>g?+require("node:tty").isatty(a):0,getuid:()=>globalThis.process?.getuid?globalThis.process.getuid():1,geteuid:()=>globalThis.process?.geteuid?globalThis.process.geteuid():1,getgid:()=>globalThis.process?.getgid?globalThis.process.getgid():1,getegid:()=>globalThis.process?.getegid?globalThis.process.getegid():1,time:()=>performance.now(),getcwd:()=>g?globalThis.process.cwd():"/static",chdir:a=>globalThis.process.chdir(a),mkdir:(a,b)=>f.mkdirSync(a,b),rmdir:a=>f.rmdirSync(a),link:(a,b)=>f.linkSync(a,b),symlink:(a,b,c)=>f.symlinkSync(a,b,[null,"file","dir"][c]),readlink:a=>f.readlinkSync(a),unlink:a=>f.unlinkSync(a),read_dir:a=>{const
c=k(a),d=c.endsWith("/")?c:c+"/",b=new
Set();for(const
c
of
i.keys())if(c.startsWith(d)){const
a=c.slice(d.length),e=a.indexOf("/");b.add(e<0?a:a.slice(0,e))}if(f)try{for(const
c
of
f.readdirSync(a))b.add(c)}catch(f){if(b.size===0)throw f}return[...b]},opendir:a=>({dir:f.opendirSync(a),dots:[".",".."]}),readdir:a=>{if(a.dots.length>0)return a.dots.shift();var
b=a.dir.readSync()?.name;return b===undefined?null:b},closedir:a=>{a.dots=[];a.dir.closeSync()},stat:(a,b)=>u(f.statSync(a),b),lstat:(a,b)=>u(f.lstatSync(a),b),fstat:(a,b)=>u(f.fstatSync(a),b),chmod:(a,b)=>f.chmodSync(a,b),fchmod:(a,b)=>f.fchmodSync(a,b),file_exists:a=>{const
b=k(a);return i.has(b)||m.has(b)?1:f?+f.existsSync(a):0},filepath_exists:a=>{const
b=k(a);if(i.has(b)||m.has(b))return 1;if(!f)return 0;try{f.statSync(a);return 1}catch(f){if(f.code==="ENOENT"||f.code==="ENOTDIR")return 0;throw f}},is_directory:a=>{const
b=k(a);return m.has(b)?1:i.has(b)?0:+f.statSync(a).isDirectory()},is_file:a=>{const
b=k(a);return i.has(b)?1:m.has(b)?0:+f.statSync(a).isFile()},utimes:(a,b,c)=>f.utimesSync(a,b,c),truncate:(a,b)=>f.truncateSync(a,b),ftruncate:(a,b)=>f.ftruncateSync(a,b),rename:(a,b)=>{var
c;if(q&&(c=f.statSync(b,{throwIfNoEntry:!1}))&&f.statSync(a,{throwIfNoEntry:!1})?.isDirectory())if(c.isDirectory()){if(!b.startsWith(a))try{f.rmdirSync(b)}catch{}}else{var
d=new
Error(`ENOTDIR: not a directory, rename '${a}' -> '${b}'`);throw Object.assign(d,{errno:-20,code:"ENOTDIR",syscall:"rename",path:b})}f.renameSync(a,b)},tmpdir:()=>require("node:os").tmpdir(),start_fiber:a=>I(a),suspend_fiber:ac((c,b)=>new
Promise(a=>c(a,b))),resume_fiber:(a,b)=>a(b),weak_new:a=>new
WeakRef(a),weak_deref:a=>{var
b=a.deref();return b===undefined?null:b},weak_map_new:()=>new
WeakMap(),map_new:()=>new
Map(),map_get:(a,b)=>{var
c=a.get(b);return c===undefined?null:c},map_set:(a,b,c)=>a.set(b,c),map_get_or_set:(a,b,c)=>{var
d=a.get(b);if(d===undefined){a.set(b,c);return null}return d},map_delete:(a,b)=>a.delete(b),hash_string:X,log:a=>console.log(a),register_fragments:(a,b)=>{const
c=eval?.(b);e[a+".fragments"]=c},load_module:a=>{const
c=new
WebAssembly.Module(a,r),b=new
WebAssembly.Instance(c,e);Object.assign(e.OCaml,b.exports);return b.exports["_dynlink.init"]()},load_wasmo:a=>{const
b=new
DataView(a.buffer,a.byteOffset,a.byteLength),j=a.byteLength;let
d=j-22;while(d>=0&&b.getUint32(d,!0)!==0x06054b50)d--;if(d<0)throw new
Error("Invalid ZIP: EOCD not found");const
i=b.getUint32(d+16,!0),h=b.getUint16(d+10,!0),f={};let
c=i;for(let
d=0;d<h;d++){if(b.getUint32(c,!0)!==0x02014b50)throw new
Error("Invalid ZIP: bad CD entry");const
g=b.getUint16(c+28,!0),i=b.getUint16(c+30,!0),h=b.getUint16(c+32,!0),d=b.getUint32(c+42,!0),m=l.decode(a.subarray(c+46,c+46+g)),n=b.getUint32(c+24,!0),k=b.getUint16(d+26,!0),j=b.getUint16(d+28,!0),e=d+30+k+j;f[m]=a.subarray(e,e+n);c+=46+g+i+h}if(!f["code.wasm"])throw new
Error("code.wasm not found in .wasmo");const
k=new
WebAssembly.Module(f["code.wasm"],r),g=new
WebAssembly.Instance(k,e);Object.assign(e.OCaml,g.exports);const
m=l.decode(f.link_order).split("\x00");for(const
a
of
m)g.exports[a+".init"]()},register_file:(a,b)=>H(a,b),read_file:a=>i.get(k(a))??null},y={test:a=>+(typeof
a==="string"),compare:(a,b)=>a<b?-1:+(a>b),decodeStringFromUTF8Array:()=>"",encodeStringToUTF8Array:()=>0,fromCharCodeArray:()=>"",length:a=>a.length,intoCharCodeArray:()=>0},e=Object.assign({Math:ad,bindings:L,js:am,"wasm:js-string":y,"wasm:text-decoder":y,"wasm:text-encoder":y,str:new
globalThis.Proxy({},{get(a,b){return b}}),env:{}},W),r={builtins:["js-string","text-decoder","text-encoder"],importedStringConstants:"str"};function
ab(a){const
b=require("node:path"),c=b.join(b.dirname(module.filename),a);return require("node:fs/promises").readFile(c)}const
E=globalThis?.document?.currentScript?.src;function
V(a){const
b=E?new
URL(a,E):a;return fetch(b)}const
aa=g?ab:V;async function
Z(a){return g?WebAssembly.instantiate(await
a,e,r):WebAssembly.instantiateStreaming(a,e,r)}async function
Y(){e.OCaml={};const
c=[];async function
b(a,b){const
g=a[1].constructor!==Array;async function
f(){const
d=aa(aj+"/"+a[0]+".wasm");await
Promise.all(g?c:a[1].map(a=>c[a]));const
f=await
Z(d);Object.assign(b?e.env:e.OCaml,f.instance.exports)}const
d=f();c.push(d);return d}async function
a(a){for(const
c
of
a)await
b(c)}await
b(p[0],1);if(p.length>1){await
b(p[1]);const
c=new
Array(20).fill(p.slice(2).values()).map(a);await
Promise.all(c)}return{instance:{exports:Object.assign(e.env,e.OCaml)}}}const
al=await
Y();var{caml_callback:B,effect_allowed:v,caml_alloc_times:z,caml_alloc_tm:A,caml_alloc_stat:M,caml_start_fiber:R,caml_handle_uncaught_exception:C,caml_buffer:N,caml_buffer_size:O,caml_extract_bytes:P,_initialize:t}=al.instance.exports;I=G(R);var
t=G(t);if(globalThis.process?.on)globalThis.process.on("uncaughtException",(a,b)=>C(a));else if(globalThis.addEventListener)globalThis.addEventListener("error",a=>a.error&&C(a.error));await
t()})(function(a){"use strict";return{}}(globalThis))({"enable_jspi":!0,"link":[["code-6485b1d912fb52083d0d",0]],"generated":(a=>{var
c=a,b=a?.module?.export||a;return{"fragments":{"get_Array":a=>a.Array,"get_Date":a=>a.Date,"get_Error":a=>a.Error,"get_JSON":a=>a.JSON,"get_Math":a=>a.Math,"get_Object":a=>a.Object,"get_RegExp":a=>a.RegExp,"get_String":a=>a.String,"get_length":a=>a.length,"js_expr_12c48ca8":()=>a,"js_expr_21711c2a":()=>b,"js_expr_26f07992":()=>null,"meth_call_0_toString":a=>a.toString(),"obj_0":(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,A,B,C,D,E,F,G,H,I,J)=>({format:a,check:b,hover:c,inlays:d,definition:e,typeDefinition:f,references:g,renamePrepare:h,rename:i,symbols:j,completion:k,signatureHelp:l,selectionRange:m,semanticTokens:n,foldingRanges:o,inactiveRanges:p,formatWat:q,checkWat:r,symbolsWat:s,toWat:t,toWax:u,wasmToWat:v,wasmToWax:w,hoverWat:x,definitionWat:y,referencesWat:z,renamePrepareWat:A,renameWat:B,selectionRangeWat:C,foldingRangesWat:D,semanticTokensWat:E,signatureHelpWat:F,typeDefinitionWat:G,completionWat:H,inlaysWat:I,inactiveRangesWat:J}),"obj_1":(a,b,c,d,e)=>({startLine:a,startChar:b,endLine:c,endChar:d,newText:e}),"obj_10":(a,b,c,d,e,f,g,h,i,j,k)=>({name:a,kind:b,startLine:c,startChar:d,endLine:e,endChar:f,selStartLine:g,selStartChar:h,selEndLine:i,selEndChar:j,children:k}),"obj_11":(a,b,c)=>({name:a,kind:b,detail:c}),"obj_12":(a,b,c)=>({label:a,parameters:b,active:c}),"obj_13":(a,b)=>({startOff:a,endOff:b}),"obj_14":(a,b,c,d)=>({startLine:a,startChar:b,endLine:c,endChar:d}),"obj_15":(a,b,c,d)=>({startLine:a,startChar:b,endLine:c,endChar:d}),"obj_16":(a,b,c)=>({startLine:a,endLine:b,kind:c}),"obj_17":(a,b,c,d)=>({line:a,character:b,length:c,kind:d}),"obj_2":(a,b,c,d,e,f,g,h,i,j,k)=>({severity:a,message:b,startLine:c,startChar:d,endLine:e,endChar:f,warning:g,unnecessary:h,hint:i,edit:j,related:k}),"obj_3":(a,b,c,d,e)=>({message:a,startLine:b,startChar:c,endLine:d,endChar:e}),"obj_4":(a,b,c)=>({ok:a,text:b,error:c}),"obj_5":(a,b,c,d,e)=>({type:a,startLine:b,startChar:c,endLine:d,endChar:e}),"obj_6":(a,b,c)=>({line:a,char:b,label:c}),"obj_7":(a,b,c,d)=>({startLine:a,startChar:b,endLine:c,endChar:d}),"obj_8":(a,b)=>({edits:a,error:b}),"obj_9":(a,b,c,d,e)=>({startLine:a,startChar:b,endLine:c,endChar:d,newText:e}),"set_wax":(a,b)=>a.wax=b}}})(globalThis),"src":"wax_format_js.bc.wasm.assets"});
