use texturecraft_core::blend::{BlendMode,blend1,blend3};
fn main() {
let mut out=Vec::new();
for (index,mode) in BlendMode::all().enumerate() { for x in 0..9 { for y in 0..9 {
let a=[x as f32/8.0,0.25,0.8]; let b=[y as f32/8.0,0.75,0.2];
out.push(serde_json::json!({"mode":index,"a":a,"b":b,"rgb":blend3(mode,a,b),"scalar":blend1(mode,a[0],b[0])}));
}}}
println!("{}",serde_json::to_string(&out).unwrap());
}
