"""Independent C/Python persistence checks, including a dense 4K surface."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'adapters/python'))
import hamudi as h


def verify():
    library=h.Library()
    base=array.array('H',[20000,30000,40000,65535])*(4096*4096)
    expected=hashlib.sha256(memoryview(base)).hexdigest()
    start=time.monotonic()
    with h.Surface(library,4096,4096,base) as surface:
        project=surface.project();save_seconds=time.monotonic()-start
        assert project.startswith(b'HAMUDI02')
        start=time.monotonic();surface.load(project);load_seconds=time.monotonic()-start
        assert surface.width==4096 and surface.height==4096
        assert hashlib.sha256(surface.read()).hexdigest()==expected
        large=dict(width=4096,height=4096,project_bytes=len(project),import_and_save_seconds=save_seconds,
                   load_seconds=load_seconds,full_albedo_opacity_exact=True)
    # Loading must dirty defaults and channels removed from the preceding state.
    row=dict(positions=[[-1,-1,0],[1,-1,0],[0,1,0]],normals=[[0,0,1]]*3,
             uvs=[[0,0],[1,0],[.5,1]],indices=[0,1,2],parts=[dict(start=0,count=3,material=0)])
    scene=h.Scene(library,row)
    renderer=surface=None
    try:
        rgba=array.array('H',[32768,32768,32768,65535])*16
        renderer=h.Renderer(library,scene,[dict(width=4,height=4,rgba=rgba)],width=64,height=64)
        surface=h.Surface(library,4,4,rgba)
        camera=h.Camera.from_dict(dict(target=[0,0,0],yaw=0,pitch=0,distance=3,scene_radius=2))
        before=renderer.render(camera);project=surface.project()
        library.call('surface_set_default',surface.handle,1,h.F3(.02,.02,.02))
        library.call('sync_surface',renderer.handle,0,surface.handle)
        assert renderer.render(camera)!=before
        surface.load(project)
        library.call('sync_surface',renderer.handle,0,surface.handle)
        assert renderer.render(camera)==before
    finally:
        if surface:surface.close()
        if renderer:renderer.close()
        scene.close()
    with tempfile.TemporaryDirectory(prefix='hamudi-wall-') as tmp:
        path=Path(tmp)
        (path/'wall.rgba16').write_bytes(array.array('H',[32768,32768,32768,65535]).tobytes())
        packet=dict(row,materials=[dict(width=1,height=1,rgba16='wall.rgba16')],camera=dict(target=[0,0,0],yaw=0,pitch=0,distance=3,scene_radius=2))
        (path/'scene.json').write_text(json.dumps(packet))
        viewport=h.PreparedViewport(path/'scene.json',width=640,height=360)
        try:
            before=viewport.frame()
            assert viewport.materials[0]['width']==256
            assert viewport.paint(.5,.5,brush=h.Brush(radius=.06))
            after=viewport.frame();changed=sum(a!=b for a,b in zip(before,after))
            assert 50<changed<len(before)//10, 'A fine stamp must not recolor the whole constant material'
            assert viewport.undo() and viewport.frame()==before
        finally:viewport.close()
    return dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                image_io_sha256=hashlib.sha256((ROOT/'src/image_io.zig').read_bytes()).hexdigest(),
                format='HAMUDI02',large=large,load_restores_material_defaults_exact=True,
                constant_material_detailing=dict(paint_resolution=256,changed_bytes=changed,undo_exact=True),
                crc_and_truncation='covered by native unit tests',legacy_JSON='covered by native unit tests')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    options=parser.parse_args()
    result=verify()
    with options.output.open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
