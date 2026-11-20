// Native raster viewport. Uses the recovered material and BSDF functions.
struct Preview { light: vec4<f32>, color: vec4<f32>, display: vec4<f32>, ambient: vec4<f32> };
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
@fragment fn preview_fs(i: RasterVertex) -> @location(0) vec4<f32> {
    let delta = i.world - P.eye.xyz; let distance = length(delta); let dir = normalize_or(delta, P.forward.xyz);
    let s = surface(Hit(distance, i.triangle, i.bary.y, i.bary.z), P.eye.xyz, dir);
    if (s.opacity < 0.5) { discard; }
    let v = -dir; let light = normalize_or(R.light.xyz, vec3<f32>(0.0,1.0,0.0));
    var direct = bsdf_eval(bsdf_new(s,v),light).rgb * R.color.rgb * R.light.w;
    if (R.display.w > 0.5 && dot(light,s.n) > 0.0 && occluded(s.pos+s.geo*P.forward.w,light)) { direct = vec3<f32>(0.0); }
    let ambient = (s.diffuse*(vec3<f32>(1.0)-s.f0)+environment_brdf(s.f0,s.roughness,max(dot(s.n,v),0.0))) * R.ambient.rgb;
    let x = max((direct+ambient+s.emissive)*R.display.x,vec3<f32>(0.0));
    var mapped = min(x,vec3<f32>(1.0));
    if (R.display.y > 0.5) { let z=x*0.6; mapped=clamp(z*(z*2.51+0.03)/(z*(z*2.43+0.59)+0.14),vec3<f32>(0.0),vec3<f32>(1.0)); }
    return vec4<f32>(preview_srgb(mapped),1.0);
}
