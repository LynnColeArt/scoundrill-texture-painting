"""Record pinned ORIGINAL sample functions in a standalone Rust type shim.

Algorithms are extracted verbatim. The shim removes application/type-system
dependencies only. Never run this to replace evidence after a candidate failure.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def function(text, start):
    position = text.index(start)
    opening = text.index('{', position)
    depth = 1
    end = opening+1
    while depth:
        depth += (text[end]=='{')-(text[end]=='}')
        end += 1
    return text[position:end]


def main():
    upstream, target = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    inventory = json.loads((ROOT/'reference/source-inventory.json').read_text())
    expected = {r['path']:r['sha256'] for r in inventory['files']}
    brush = upstream/'crates/paint/src/brush.rs'
    noise = upstream/'crates/texel/src/noise.rs'
    for path in (brush, noise):assert sha(path)==expected[str(path.relative_to(upstream))]
    text = brush.read_text()
    sample = function(text, 'pub fn sample(self, lx: f32')
    smooth = function(text, 'pub(crate) fn smoothstep(')
    names = ['Round','Square','Star','Grunge','Spray','Cloud','Streaks']
    source = '#[path='+json.dumps(str(noise))+'] mod noise;\n'
    source += '#[derive(Clone,Copy)] enum BrushAlpha{'+','.join(names)+'}\n'
    source += 'impl BrushAlpha{'+sample+'}\n'+smooth+'\n'
    source += r'''
fn main(){
    let alphas=[BrushAlpha::Round,BrushAlpha::Square,BrushAlpha::Star,BrushAlpha::Grunge,BrushAlpha::Spray,BrushAlpha::Cloud,BrushAlpha::Streaks];
    for (i,a) in alphas.iter().enumerate(){for hard in [0.1f32,0.8,1.0]{for seed in [0,7]{for y in -8..=8{for x in -8..=8{
        let (u,v)=(x as f32/8.0,y as f32/8.0);
        println!("[{},{:?},{:?},{:?},{},{}]",i,u,v,hard,seed,a.sample(u,v,hard,seed).to_bits());
    }}}}}
}
'''
    with tempfile.TemporaryDirectory(prefix='hamudi-brush-oracle-') as tmp:
        path = Path(tmp)/'original.rs';path.write_text(source)
        executable = Path(tmp)/'original'
        subprocess.run(['rustc','--edition','2024','-O',str(path),'-o',str(executable)],check=True)
        rows = [json.loads(line) for line in subprocess.check_output([str(executable)],text=True).splitlines()]
        # Verify the unchanged original noise source's own retained bit checksum.
        subprocess.run(['rustc','--edition','2024','--test',str(noise),'-o',str(executable)],check=True)
        subprocess.run([str(executable),'--exact','tests::noises_match_the_reference_bit_for_bit'],check=True,stdout=sys.stderr)
    with target.open('x') as stream:json.dump(rows,stream,separators=(',',':'));stream.write('\n')
    metadata = dict(upstream_commit=inventory['commit'],cases=len(rows),brush_source_sha256=sha(brush),noise_source_sha256=sha(noise),
                    shim_source_sha256=hashlib.sha256(source.encode()).hexdigest(),fixture_sha256=sha(target),
                    noise_checksum='67e814aa2127b333',noise_observations=58366,
                    scope='Seven unchanged procedural alpha sample functions; 17x17 grid, three hardnesses, two seeds; Rust application type shim only')
    print(json.dumps(metadata,indent=2))


if __name__=='__main__':main()
