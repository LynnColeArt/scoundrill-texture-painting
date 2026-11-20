#!/usr/bin/env python3
"""Build and reproduce library, consumer, renderer and workflow acceptance.

Original evidence is read only. --full adds GPU/reference/4K measurements.
Output directories must be new, so a run never overwrites previous evidence.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_hash():
    names = [ROOT / 'build.zig', ROOT / 'build.zig.zon', ROOT / 'run.py']
    for folder in ('src', 'include', 'adapters'):
        names.extend(p for p in (ROOT / folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    names = sorted(names)
    return hashlib.sha256(''.join(str(p.relative_to(ROOT)) + ':' + sha(p) + '\n' for p in names).encode()).hexdigest()


def run(command, *, cwd=ROOT, timeout=300):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    start = time.monotonic()
    result = subprocess.run(list(map(str, command)), cwd=cwd, capture_output=True, timeout=timeout)
    if result.returncode:
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        raise RuntimeError('Command failed: ' + str(command))
    return dict(seconds=time.monotonic()-start, stdout=result.stdout.decode(errors='replace'), stderr=result.stderr.decode(errors='replace'))


def bindings():
    spec = importlib.util.spec_from_file_location('hamudi_acceptance', ROOT / 'adapters/python/hamudi.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def consumer_checks(prepared, output):
    from PIL import Image
    import io
    h = bindings()
    with h.Surface(h.Library(),4,4) as sample:
        assert Image.open(io.BytesIO(sample.png(channel=1,bits=8))).getpixel((0,0))[0]==128
        assert Image.open(io.BytesIO(sample.png(channel=0,bits=8))).getpixel((0,0))[0]==188
    vp = h.PreparedViewport(prepared, width=640, height=360)
    try:
        original = vp.frame()
        assert vp.begin_paint(.5, .23, expected_revision=0)
        vp.continue_paint(.51, .235)
        assert vp.revision == 0
        assert vp.frame() != original
        vp.finish_paint(cancel=True)
        assert vp.frame() == original, 'Cancel must restore the exact preceding frame'
        assert not vp.history
        assert vp.begin_paint(.5, .23, expected_revision=0)
        vp.continue_paint(.51, .235)
        vp.finish_paint()
        painted = vp.frame()
        assert painted != original and vp.revision == 1 and len(vp.history) == 1
        assert vp.undo() and vp.frame() == original
        assert vp.redo() and vp.frame() == painted
        try:
            vp.begin_paint(.5, .23, expected_revision=0)
            raise AssertionError('Stale revision accepted')
        except RuntimeError as error:
            assert 'StaleRevision' in str(error)
        skin = vp.surfaces[0]
        project, png = skin.project(), skin.png()
        prior = skin.read()
        skin.load(project)
        assert skin.read() == prior
        (output / 'makeup.png').write_bytes(h.display_png(640, 360, painted))
        (output / 'painted-skin.png').write_bytes(png)
        # A no-UV garment must be editable after native chart generation.
        assert vp.paint(.5, .30, (1, 1, 1), h.Brush(radius=.15), channel=2)
        garment = vp.frame()
        assert garment != painted
        assert vp.undo() and vp.frame() == painted
        # Source vertices still drive the UV-split geometry and all its copies.
        data = vp.data
        shifted = [[p[0]+.2, p[1], p[2]] for p in data['positions']]
        vp.deform(shifted, data['normals'])
        assert vp.frame() != painted
        vp.deform(data['positions'], data['normals'])
        assert vp.frame() == painted
        bad = [p[:] for p in data['positions']]
        bad[-1][0] = float('nan')
        try:
            vp.deform(bad, data['normals'])
            raise AssertionError('Invalid pose accepted')
        except RuntimeError as error:
            assert 'NonFiniteMesh' in str(error)
        assert vp.frame() == painted
        # Progressive work yields control between every bounded native batch.
        count = 0
        def cancelled(): return count >= 1
        for _, frame in vp.renderer.progressive(vp.camera, samples=32, cancel=cancelled):
            count += 1
            assert len(frame) == 640*360*4
        assert count == 1
        # Repeated warm paint + visible frame timings, with deterministic cleanup.
        timings = []
        for _ in range(10):
            start = time.monotonic()
            assert vp.begin_paint(.5, .23)
            vp.continue_paint(.505, .23)
            vp.frame()
            timings.append((time.monotonic()-start)*1000)
            vp.finish_paint(cancel=True)
        begin_ms, drag_ms, reference_ms = [], [], []
        for _ in range(10):
            start=time.monotonic();assert vp.begin_paint(.5,.23);vp.frame();begin_ms.append((time.monotonic()-start)*1000)
            start=time.monotonic();vp.continue_paint(.505,.23);vp.frame();drag_ms.append((time.monotonic()-start)*1000)
            vp.finish_paint(cancel=True)
        # Same transport as the accepted warm profile, one progressive sample
        # while dragging. Stationary preview can continue converging afterwards.
        vp.frame(traced=True,samples=1)
        for _ in range(10):
            start=time.monotonic();assert vp.begin_paint(.5,.23);vp.frame(traced=True,samples=1);reference_ms.append((time.monotonic()-start)*1000)
            vp.finish_paint(cancel=True)
        return dict(live_preview=True, cancel_exact=True, grouped_undo_exact=True, redo_exact=True,
                    stale_revision_rejected=True, native_project_roundtrip=True, garment_metallic_paint=True,
                    uv_split_deformation=True, invalid_pose_atomic=True, progressive_cancel_between_batches=True,
                    project_bytes=len(project),png_color_and_data_defaults=True,warm_brush_to_readback_ms=timings,
                    warm_begin_to_readback_ms=begin_ms,warm_drag_to_readback_ms=drag_ms,
                    warm_reference_one_sample_begin_ms=reference_ms)
    finally:
        vp.close()


def reference_checks(inputs, source, output, *, benchmark, zig):
    import numpy as np
    from PIL import Image
    reports, frames, differences = {}, {}, {}
    cases = [('studio', 128, source / 'experiments/texturecraft/results/texturecraft-studio-traced.png')]
    room = source / 'experiments/texturecraft/room/results'
    cases += [(name, samples, room / (original + '.png')) for name, samples, original in [
        ('window-open',256,'window-open-traced'), ('window-closed',256,'window-closed-traced'),
        ('lamp-left',512,'lamp-left-traced'), ('lamp-left-off',512,'lamp-off-traced'), ('lamp-right',512,'lamp-right-traced')]]
    for name, samples, original in cases:
        target = output / (name + '.ppm')
        wall = run([ROOT/'zig-out/bin/hamudi', inputs/(name+'.json'), target, 1280, 720, samples, 'gpu'])
        reports[name] = dict(json.loads(Path(str(target)+'.json').read_text()), process_seconds=wall['seconds'])
        frame = np.asarray(Image.open(target).convert('RGB'), dtype=np.int16)
        frames[name] = frame
        reference = np.asarray(Image.open(original).convert('RGB'), dtype=np.int16)
        delta = abs(frame-reference)
        differences[name] = dict(mean=float(delta.mean()), maximum=int(delta.max()),
                                 fraction_above_3=float((delta>3).mean()), original_sha256=sha(original),
                                 input_sha256=sha(inputs/(name+'.json')))
        # Broad image energy check complements the lighting controls below.
        # Maximum differences are recorded, not relabelled as original CPU/GPU parity.
        assert delta.mean() < .5, (name, differences[name])
        if name in ('studio','lamp-right'):
            Image.open(target).save(output/(name+'.png'))
        target.unlink()
    floor, actor = np.s_[545:650,400:1000,:], np.s_[290:530,565:700,:]
    checks = dict(open_floor=float(frames['window-open'][floor].mean()), closed_floor=float(frames['window-closed'][floor].mean()),
                  lamp_on_off_actor=float(abs(frames['lamp-left'][actor]-frames['lamp-left-off'][actor]).mean()),
                  lamp_position_actor=float(abs(frames['lamp-left'][actor]-frames['lamp-right'][actor]).mean()))
    assert checks['open_floor'] > checks['closed_floor']+2 and checks['closed_floor']<1
    assert checks['lamp_on_off_actor']>5 and checks['lamp_position_actor']>3
    smoke = output/'cpu-smoke.ppm'
    run([ROOT/'zig-out/bin/hamudi',inputs/'scene.json',smoke,32,18,1,'cpu'], timeout=180)
    cpu = json.loads(Path(str(smoke)+'.json').read_text())
    assert 'llvmpipe' in cpu['adapter'] or 'CPU' in cpu['adapter']
    smoke.unlink()
    if benchmark:
        for w, height in ((1280,720),(1920,1080),(3840,2160)):
            target = output/f'raster-{w}.ppm'
            run([ROOT/'zig-out/bin/hamudi',inputs/'window-open.json',target,w,height,60,'raster'])
            report = json.loads(Path(str(target)+'.json').read_text())
            ms = report['warm_frame_ms_without_readback']
            report['distribution_ms'] = dict(mean=float(np.mean(ms)),p50=float(np.percentile(ms,50)),p95=float(np.percentile(ms,95)),p99=float(np.percentile(ms,99)))
            reports[f'raster-{w}'] = report
            target.unlink()
        target = output/'warm-reference-4k.ppm'
        peak = output/'4k-peak-rss-kib.txt'
        wall = run(['/usr/bin/time','-f','%M','-o',peak,ROOT/'zig-out/bin/hamudi',inputs/'lamp-right.json',target,3840,2160,512,'gpu'], timeout=300)
        reports['traced-4k'] = dict(json.loads(Path(str(target)+'.json').read_text()),process_seconds=wall['seconds'],peak_process_rss_kib=int(peak.read_text()))
        Image.open(target).save(output/'warm-reference-4k.png')
        target.unlink()
        baseline = output/'host-storage-build'
        run([zig,'build','-Doptimize=ReleaseSafe','-Dhost-buffers=true','--prefix',baseline])
        target=output/'host-storage-4k.ppm';peak=output/'host-storage-peak-rss-kib.txt'
        wall=run(['/usr/bin/time','-f','%M','-o',peak,baseline/'bin/hamudi',inputs/'lamp-right.json',target,3840,2160,512,'gpu'],timeout=300)
        baseline_report=json.loads(Path(str(target)+'.json').read_text())
        baseline_report.update(process_seconds=wall['seconds'],peak_process_rss_kib=int(peak.read_text()))
        reference_pixels=np.asarray(Image.open(output/'warm-reference-4k.png'))
        assert np.array_equal(reference_pixels,np.asarray(Image.open(target))), 'Memory placement changed pixels'
        baseline_report['device_local_pixels_exact']=True
        reports['host-storage-4k']=baseline_report
        target.unlink()
        shutil.rmtree(baseline)
    return dict(controls=checks, differences=differences, renders=reports, cpu_smoke=cpu)


def light_sweep_checks(inputs):
    h=bindings();vp=h.PreparedViewport(inputs/'window-sweep.json',width=640,height=360)
    try:
        frames=[]
        for light in vp.data['light_sweep']:
            vp.data['light']=light;frames.append(vp.frame())
        assert frames[0]==frames[-1], 'Returning to a light must restore exact raster pixels'
        changed=[sum(a!=b for a,b in zip(frames[0],frame)) for frame in frames[1:-1]]
        assert min(changed)>1000
        return dict(return_exact=True,changed_bytes=changed)
    finally:vp.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default=shutil.which('zig'))
    parser.add_argument('--scoundrill', type=Path, default=ROOT.parent/'scoundrill')
    parser.add_argument('--full', action='store_true')
    parser.add_argument('--output', type=Path)
    options = parser.parse_args()
    if not options.zig:parser.error('Zig 0.16.0 is required')
    if options.output:
        options.output.mkdir(parents=True, exist_ok=False)
        output = options.output.resolve()
    else:
        output = Path(tempfile.mkdtemp(prefix='hamudi-acceptance-'))
    version = run([options.zig,'version'])['stdout'].strip()
    assert version=='0.16.0', version
    report = dict(schema_version=1,zig=version,source_sha256=source_hash(),
                  commit=run(['git','rev-parse','HEAD'])['stdout'].strip(),checks={},
                  timing_scope='Shared development machine; this runner submits its GPU workloads sequentially. No cross-renderer speedup is inferred.')
    for index in ('baseline-index.json','behavior-index.json'):
        document=json.loads((ROOT/'reference'/index).read_text())
        for entry in document['files']:
            assert sha(options.scoundrill/entry['path'])==entry['sha256'], 'Original reference changed: '+entry['path']
    assert sha(ROOT/'src/fixtures/blend-goldens.json')==json.loads((ROOT/'reference/core-goldens.json').read_text())['sha256']
    assert sha(ROOT/'src/fixtures/brush-goldens.json')==json.loads((ROOT/'reference/brush-goldens.json').read_text())['fixture_sha256']
    report['original_reference_hashes_unchanged']=True
    for mode in ('Debug','ReleaseSafe'):
        report['checks']['core-'+mode] = run([options.zig,'build','test','-Dgpu=false','-Doptimize='+mode])
    report['checks']['renderer-numerical'] = run([options.zig,'build','renderer-test'])
    report['checks']['c-consumer'] = run([options.zig,'build','integration'])
    report['checks']['build'] = run([options.zig,'build','-Doptimize=ReleaseSafe'])
    if options.full:
        report['checks']['gpu-Debug'] = run([options.zig,'build','gpu-test'])
        report['checks']['gpu-ReleaseSafe'] = run([options.zig,'build','gpu-test','-Doptimize=ReleaseSafe'])
        report['checks']['workflows'] = run([ROOT/'zig-out/bin/hamudi-workflows',output/'workflows'])
        with tempfile.TemporaryDirectory(prefix='hamudi-prepared-') as tmp:
            inputs = Path(tmp)/'input'
            run([sys.executable,options.scoundrill/'experiments/texturecraft/room/prepare_room.py',inputs])
            report['consumer'] = consumer_checks(inputs/'scene.json',output)
            report['light_sweep'] = light_sweep_checks(inputs)
            report['reference'] = reference_checks(inputs,options.scoundrill,output,benchmark=True,zig=options.zig)
        report['hardware'] = run(['nvidia-smi','--query-gpu=name,driver_version,memory.total','--format=csv,noheader'])['stdout'].strip()
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS: '+str(output/'report.json'),flush=True)


if __name__=='__main__':main()
