//! Development-only WGSL to SPIR-V compiler. No Rust code is linked into hamudi-1.
use std::{env, fs, path::Path};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = env::args().nth(1).ok_or("expected project root")?;
    let root = Path::new(&root);
    let rays = fs::read_to_string(root.join("shaders/upstream/rays.wgsl"))?;
    let trace = fs::read_to_string(root.join("shaders/generated/trace.wgsl"))?;
    let post = fs::read_to_string(root.join("shaders/generated/post.wgsl"))?;
    let trace = format!("{rays}\n{trace}");
    fs::create_dir_all(root.join("src/spirv"))?;
    for (name, source) in [("trace_main", &trace), ("denoise_init", &post), ("denoise_step", &post), ("resolve", &post)] {
        let module = naga::front::wgsl::parse_str(source).map_err(|e| e.emit_to_string(source))?;
        let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::all()).validate(&module)?;
        let options = naga::back::spv::Options { lang_version: (1, 3), ..Default::default() };
        let pipeline = naga::back::spv::PipelineOptions { shader_stage: naga::ShaderStage::Compute, entry_point: name.to_string() };
        let words = naga::back::spv::write_vec(&module, &info, &options, Some(&pipeline))?;
        let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
        fs::write(root.join(format!("src/spirv/{name}.spv")), bytes)?;
        println!("compiled {name}");
    }
    Ok(())
}
