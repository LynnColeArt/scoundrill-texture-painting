"""Adapt resource access only; light transport stays in the pinned WGSL source."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'shaders/upstream/trace.wgsl').read_text()
source = source.replace('@group(0) @binding(9) var env_tex: texture_2d<f32>;', '@group(0) @binding(9) var<storage, read> env_pixels: array<vec4<f32>>;')
source, count = re.subn(r'@group\(0\) @binding\(1[0-7]\) var t_\w+: texture_2d_array<f32>;', '', source)
assert count == 8
source = source.replace('textureDimensions(env_tex)', 'vec2<u32>(P.env.zw)')
source = source.replace('textureLoad(env_tex, vec2<i32>(xx, yy), 0)', 'env_pixels[u32(yy) * u32(dims.x) + u32(xx)]')
for kind, name in enumerate(['base', 'orm', 'normal', 'height', 'emissive', 'lobes', 'sheen', 'extra']):
    source, count = re.subn(r'textureLoad\(t_' + name + r', (texel\(layer, \d+u, uv, -?\d+, -?\d+\)), layer, 0\)', rf'load_kind(layer, {kind}u, \1)', source)
    assert count == (5 if name == 'height' else 1), (name, count)
access = '''
@group(0) @binding(10) var<storage, read> material_words: array<u32>;
@group(0) @binding(11) var<storage, read> material_offsets: array<u32>;
fn decode_srgb(c: vec3<f32>) -> vec3<f32> {
    return select(pow((c + 0.055) / 1.055, vec3<f32>(2.4)), c / 12.92, c <= vec3<f32>(0.04045));
}
fn load_kind(layer: u32, kind: u32, xy: vec2<i32>) -> vec4<f32> {
    let small = ((u32(P.sets[layer].z) >> kind) & 1u) != 0u;
    let width = select(u32(P.sets[layer].x), 1u, small);
    var index = u32(xy.y) * width + u32(xy.x);
    var base = material_offsets[layer * 8u + kind];
    if (((u32(P.sets[layer].z) >> (kind + 8u)) & 1u) != 0u) {
        let stride = select(1u, 2u, kind == 2u || kind == 3u);
        let tile = (u32(xy.y) / 64u) * ((width + 63u) / 64u) + u32(xy.x) / 64u;
        let page = material_words[base + stride + tile];
        index = 0u;
        if (page != 0u) {
            base = page;
            index = (u32(xy.y) % 64u) * 64u + u32(xy.x) % 64u;
        }
    }
    if (kind == 2u || kind == 3u) {
        return vec4<f32>(unpack2x16float(material_words[base + index * 2u]), unpack2x16float(material_words[base + index * 2u + 1u]));
    }
    let p = unpack4x8unorm(material_words[base + index]);
    if (kind == 0u || kind == 4u || kind == 6u) { return vec4<f32>(decode_srgb(p.rgb), p.a); }
    return p;
}
'''
out = ROOT / 'shaders/generated'
out.mkdir(exist_ok=True)
(out / 'trace.wgsl').write_text(access + source)
post = (ROOT / 'shaders/upstream/trace_post.wgsl').read_text()
post = post.replace('@group(0) @binding(7) var out: texture_storage_2d<rgba8unorm, write>;', '@group(0) @binding(7) var<storage, read_write> out: array<u32>;')
assert 'textureStore(out, vec2<i32>(id.xy), vec4<f32>(to_srgb(c), 1.0));' in post
post = post.replace('textureStore(out, vec2<i32>(id.xy), vec4<f32>(to_srgb(c), 1.0));', 'out[i] = pack4x8unorm(vec4<f32>(to_srgb(c), 1.0));')
(out / 'post.wgsl').write_text(post)
