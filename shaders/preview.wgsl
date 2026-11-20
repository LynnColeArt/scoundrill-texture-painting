// Native raster viewport. Uses the recovered material and BSDF functions.
struct Preview { light: vec4<f32>, color: vec4<f32>, display: vec4<f32>, ambient: vec4<f32>, sh: array<vec4<f32>,9>, mips: array<vec4<u32>,8>, counts: vec4<u32>, inverse_vp: mat4x4<f32> };
@group(0) @binding(12) var<uniform> R: Preview;
struct RasterVertex {
    @builtin(position) clip: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) bary: vec3<f32>,
    @location(2) @interpolate(flat) triangle: u32,
};
@vertex fn preview_vs(@builtin(vertex_index) index: u32) -> RasterVertex {
    let tri = index / 3u; let corner = index % 3u;
    let p = tri_p(tri, corner); var clip = P.inv_vp * vec4<f32>(p, 1.0);
    var bary = vec3<f32>(0.0); bary[corner] = 1.0;
    return RasterVertex(clip, p, bary, tri);
}
fn preview_srgb(v: vec3<f32>) -> vec3<f32> {
    let c = clamp(v, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(1.055 * pow(c, vec3<f32>(1.0/2.4)) - 0.055, c * 12.92, c <= vec3<f32>(0.0031308));
}
fn environment_brdf(f0: vec3<f32>, rough: f32, nov: f32) -> vec3<f32> {
    let r = rough * vec4<f32>(-1.0,-0.0275,-0.572,0.022) + vec4<f32>(1.0,0.0425,1.04,-0.04);
    let a = min(r.x*r.x, exp2(-9.28*nov))*r.x+r.y;
    let ab = vec2<f32>(-1.04,1.04)*a+r.zw;
    return f0*ab.x+ab.y;
}
fn diffuse_environment(n: vec3<f32>) -> vec3<f32> {
    let d=to_env(n);let x=d.x;let y=d.y;let z=d.z;
    return max(R.sh[0].xyz*0.282095+R.sh[1].xyz*(0.488603*y)+R.sh[2].xyz*(0.488603*z)+R.sh[3].xyz*(0.488603*x)+R.sh[4].xyz*(1.092548*x*y)+R.sh[5].xyz*(1.092548*y*z)+R.sh[6].xyz*(0.315392*(3.0*z*z-1.0))+R.sh[7].xyz*(1.092548*x*z)+R.sh[8].xyz*(0.546274*(x*x-y*y)),vec3<f32>(0.0));
}
fn mip_texel(level:u32,x:i32,y:i32) -> vec3<f32> {
    let info=R.mips[level];let w=i32(info.x);let h=i32(info.y);return env_pixels[info.z+u32(clamp(y,0,h-1))*info.x+u32(((x%w)+w)%w)].rgb;
}
fn mip_sample(level:u32,d:vec3<f32>) -> vec3<f32> {
    let f=uv_of(d)*vec2<f32>(R.mips[level].xy)-0.5;let x=i32(floor(f.x));let y=i32(floor(f.y));let t=fract(f);
    return mix(mix(mip_texel(level,x,y),mip_texel(level,x+1,y),t.x),mix(mip_texel(level,x,y+1),mip_texel(level,x+1,y+1),t.x),t.y);
}
fn specular_environment(n:vec3<f32>,rough:f32) -> vec3<f32> {
    let d=to_env(n);let lod=rough*f32(max(R.counts.x,1u)-1u);let lower=u32(floor(lod));let upper=min(lower+1u,R.counts.x-1u);
    return mix(mip_sample(lower,d),mip_sample(upper,d),fract(lod));
}
fn preview_tone(hdr:vec3<f32>) -> vec3<f32> {
    let x=max(hdr*R.display.x,vec3<f32>(0.0));if(R.display.y<0.5){return min(x,vec3<f32>(1.0));}let z=x*0.6;return clamp(z*(z*2.51+0.03)/(z*(z*2.43+0.59)+0.14),vec3<f32>(0.0),vec3<f32>(1.0));
}
@vertex fn background_vs(@builtin(vertex_index) index:u32) -> @builtin(position) vec4<f32> {
    var p=array<vec2<f32>,3>(vec2<f32>(-1.0,-1.0),vec2<f32>(3.0,-1.0),vec2<f32>(-1.0,3.0));return vec4<f32>(p[index],1.0,1.0);
}
@fragment fn background_fs(@builtin(position) frag:vec4<f32>) -> @location(0) vec4<f32> {
    let ndc=vec2<f32>(frag.x/f32(P.size.x)*2.0-1.0,1.0-frag.y/f32(P.size.y)*2.0);let a=R.inverse_vp*vec4<f32>(ndc,0.0,1.0);let b=R.inverse_vp*vec4<f32>(ndc,1.0,1.0);let d=normalize_or(b.xyz/b.w-a.xyz/a.w,P.forward.xyz);
    let c=mix(vec3<f32>(0.03),preview_tone(env(d)),R.display.z);return vec4<f32>(preview_srgb(c),1.0);
}
@fragment fn preview_fs(i: RasterVertex) -> @location(0) vec4<f32> {
    let delta = i.world - P.eye.xyz; let distance = length(delta); let dir = normalize_or(delta, P.forward.xyz);
    let s = surface(Hit(distance, i.triangle, i.bary.y, i.bary.z), P.eye.xyz, dir);
    if (s.opacity < 0.5) { discard; }
    let v = -dir; let light = normalize_or(R.light.xyz, vec3<f32>(0.0,1.0,0.0));
    var direct = bsdf_eval(bsdf_new(s,v),light).rgb * R.color.rgb * R.light.w;
    if (R.display.w > 0.5 && dot(light,s.n) > 0.0 && occluded(s.pos+s.geo*P.forward.w,light)) { direct = vec3<f32>(0.0); }
    let ambient = s.diffuse*(vec3<f32>(1.0)-s.f0)*diffuse_environment(s.n)+environment_brdf(s.f0,s.roughness,max(dot(s.n,v),0.0))*specular_environment(reflect(-v,s.n),s.roughness);
    let mapped=preview_tone(direct+ambient+s.emissive);
    return vec4<f32>(preview_srgb(mapped),1.0);
}
