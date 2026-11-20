"""ABI 1 bindings. Rendering and painting run in the native Zig libraries."""
from __future__ import annotations
import array
import ctypes as C
import json
import math
from pathlib import Path
import struct
import sys
import zlib

F3 = C.c_float * 3
F4 = C.c_float * 4
H = C.c_uint64
P = C.c_void_p
U = C.c_uint32
Z = C.c_size_t

class Mesh(C.Structure):
    _fields_ = [(n, P) for n in ('positions', 'normals', 'uvs', 'indices', 'materials')] + [('vertex_count', Z), ('index_count', Z)]

class Material(C.Structure):
    _fields_ = [('width', U), ('height', U), ('rgba', P), ('base', F3), ('opacity', C.c_float), ('roughness', C.c_float), ('metallic', C.c_float), ('emissive', F3)]

class Camera(C.Structure):
    _fields_ = [('target', F3)] + [(n, C.c_float) for n in ('yaw', 'pitch', 'distance', 'fov', 'scene_radius')] + [('ortho', U)]
    @classmethod
    def from_dict(cls, row):
        return cls(F3(*row.get('target', [0,0,0])), row.get('yaw', .7), row.get('pitch', .25), row.get('distance', 3), row.get('fov', 45), row.get('scene_radius', 1), row.get('ortho', False))
    def eye(self):
        return F3(self.target[0] + math.cos(self.pitch)*math.sin(self.yaw)*self.distance,
                  self.target[1] + math.sin(self.pitch)*self.distance,
                  self.target[2] + math.cos(self.pitch)*math.cos(self.yaw)*self.distance)

class Brush(C.Structure):
    _fields_ = [(n, C.c_float) for n in ('radius', 'hardness', 'flow', 'spacing', 'angle')] + [('alpha', U)]
    def __init__(self, radius=.05, hardness=.8, flow=1., spacing=.15, angle=0., alpha=0):
        super().__init__(radius, hardness, flow, spacing, angle, alpha)

class Hit(C.Structure):
    _fields_ = [('point', F3), ('normal', F3), ('uv', C.c_float*2), ('triangle', U), ('material', U)]

class Library:
    def __init__(self, path=None):
        path = Path(path) if path else Path(__file__).resolve().parents[2] / 'zig-out/lib/libhamudi.so'
        self.api = C.CDLL(str(path))
        signatures = {
            'renderer_create': [P], 'surface_create': [U,U,P], 'release': [H],
            'set_mesh': [H,P], 'set_materials': [H,P,Z], 'set_environment': [H,P], 'resize': [H,U,U],
            'preview': [H,P,P,C.c_float,U,P,Z], 'trace': [H,P,U,C.c_float,U,P,Z],
            'update_region': [H,U,U,U,U,U,P], 'surface_add_layer': [H,P,Z,P],
            'surface_stroke_uv': [H,U,U,P,C.c_float,U,P,Z,P], 'surface_read': [H,U,P,Z],
            'surface_undo':[H], 'surface_redo':[H], 'scene_create':[P,P], 'set_scene':[H,H],
            'pick':[H,P,C.c_float,C.c_float,C.c_float,P], 'surface_import_base':[H,P,Z],
            'surface_stamp_world':[H,H,U,U,U,P,P,P,P,P], 'sync_surface':[H,U,H],
            'surface_clear_dirty':[H], 'surface_save':[H,P,Z,P], 'surface_load':[H,P,Z],
            'surface_png':[H,U,U,U,P,Z,P], 'surface_set_default':[H,U,P], 'material_height':[H,U,C.c_float],
            'scene_unwrap_missing':[H,P],
        }
        for name, args in signatures.items():
            fn = getattr(self.api, 'hamudi_'+name); fn.argtypes=args; fn.restype=C.c_int
        self.api.hamudi_last_error.restype=C.c_char_p
        self.api.hamudi_abi_version.restype=U
        if self.api.hamudi_abi_version()!=1:
            raise RuntimeError('Unsupported hamudi ABI')
    def call(self, name, *args):
        result=getattr(self.api, 'hamudi_'+name)(*args)
        if result<0:
            raise RuntimeError(self.api.hamudi_last_error().decode('utf-8'))
        return result

def _buffer(typecode, values):
    data=array.array(typecode, values)
    return data, (C.c_char * len(data.tobytes())).from_buffer(data)

class Resource:
    def close(self):
        if self.handle.value:
            self.library.call('release', self.handle); self.handle.value=0
    def __enter__(self): return self
    def __exit__(self, *_): self.close()

class Scene(Resource):
    def __init__(self, library, row):
        self.library=library; self.handle=H()
        keep=[]
        pointers=[]
        for key in ('positions','normals','uvs','indices'):
            values=row[key]
            if key!='indices': values=(v for vector in values for v in vector)
            data, buf=_buffer('I' if key=='indices' else 'f',values);keep.extend([data,buf]);pointers.append(C.cast(buf,P))
        material_ids=[0]*(len(row['indices'])//3)
        for part in row['parts']:
            start=part['start'];count=part['count']
            if start%3 or count%3 or start<0 or count<0 or start+count>len(row['indices']): raise ValueError('Invalid mesh part')
            material_ids[start//3:(start+count)//3]=[part['material']]*(count//3)
        data,buf=_buffer('I',material_ids);keep.extend([data,buf]);pointers.append(C.cast(buf,P))
        mesh=Mesh(*pointers,len(row['positions']),len(row['indices']))
        library.call('scene_create',C.byref(mesh),C.byref(self.handle))
    def pick(self, camera, u, v, aspect):
        hit=Hit()
        return hit if self.library.call('pick',self.handle,C.byref(camera),u,v,aspect,C.byref(hit))==0 else None

class Surface(Resource):
    def __init__(self,library,width,height,base=None,roughness=.5,metallic=0.):
        self.library=library;self.handle=H();self.width=width;self.height=height
        library.call('surface_create',width,height,C.byref(self.handle))
        try:
            if base is not None:
                data,buf=_buffer('H',base);library.call('surface_import_base',self.handle,buf,len(data))
            layer=U();name=b'Paint';library.call('surface_add_layer',self.handle,name,len(name),C.byref(layer));self.layer=layer.value
            library.call('surface_set_default',self.handle,1,F3(roughness,roughness,roughness));library.call('surface_set_default',self.handle,2,F3(metallic,metallic,metallic))
            if base is not None: library.call('surface_clear_dirty',self.handle)
        except BaseException:
            self.close();raise
    def stroke_uv(self,points,color=(1,0,0),brush=None,channel=0):
        data,buf=_buffer('f',(v for uv in points for v in uv));b=brush or Brush()
        self.library.call('surface_stroke_uv',self.handle,self.layer,channel,F3(*color),1.,0,buf,len(data)//2,C.byref(b))
    def read(self,channel=0):
        out=(C.c_uint16*(self.width*self.height*4))()
        self.library.call('surface_read',self.handle,channel,out,len(out));return bytes(out)
    def undo(self): return self.library.call('surface_undo',self.handle)==0
    def redo(self): return self.library.call('surface_redo',self.handle)==0
    def project(self):
        required=Z();self.library.call('surface_save',self.handle,None,0,C.byref(required))
        output=C.create_string_buffer(required.value);self.library.call('surface_save',self.handle,output,len(output),C.byref(required));return output.raw
    def load(self,data):
        self.library.call('surface_load',self.handle,data,len(data));row=json.loads(data);self.width=row['width'];self.height=row['height'];self.layer=len(row['layers'])-1
    def png(self,channel=0,bits=16,color=True):
        required=Z();self.library.call('surface_png',self.handle,channel,bits,color,None,0,C.byref(required))
        output=C.create_string_buffer(required.value);self.library.call('surface_png',self.handle,channel,bits,color,output,len(output),C.byref(required));return output.raw

class Renderer(Resource):
    def __init__(self,library,scene,materials,environment=(.5,.5,.5),width=1280,height=720):
        self.library=library;self.handle=H();library.call('renderer_create',C.byref(self.handle))
        try:
            library.call('set_scene',self.handle,scene.handle)
            entries=(Material*len(materials))();keep=[]
            for entry,mat in zip(entries,materials):
                data,buf=_buffer('H',mat['rgba']);keep.extend([data,buf])
                entry.width=mat['width'];entry.height=mat['height'];entry.rgba=C.cast(buf,P);entry.base=F3(.5,.5,.5);entry.opacity=1.;entry.roughness=mat.get('roughness',.5);entry.metallic=mat.get('metallic',0);entry.emissive=F3(*mat.get('emissive',[0,0,0]))
            library.call('set_materials',self.handle,entries,len(entries));library.call('set_environment',self.handle,F3(*environment));self.resize(width,height)
        except BaseException:
            self.close();raise
    def resize(self,width,height):
        self.library.call('resize',self.handle,width,height);self.width=width;self.height=height;self.output=(C.c_uint8*(width*height*4))()
    def render(self,camera,*,traced=False,samples=8,light=(-.5,1,.5,3),exposure=1.,filmic=True):
        if traced:self.library.call('trace',self.handle,C.byref(camera),samples,exposure,filmic,self.output,len(self.output))
        else:self.library.call('preview',self.handle,C.byref(camera),F4(*light),exposure,filmic,self.output,len(self.output))
        return bytes(self.output)

class PreparedViewport:
    """Scoundrill prepared-scene adapter, with persistent rendering and painting."""
    def __init__(self,path,library_path=None,width=1280,height=720):
        self.library=Library(library_path);self.scene=None;self.renderer=None;self.surfaces={};self.history=[];self.redo_history=[]
        path=Path(path).resolve()
        if path.stat().st_size>64*1024*1024:raise ValueError('Scene exceeds budget')
        self.data=json.loads(path.read_text());self.camera=Camera.from_dict(self.data['camera']);self.materials=[]
        try:
            for mat in self.data['materials']:
                texture=(path.parent/mat['rgba16']).resolve()
                if not texture.is_relative_to(path.parent):raise ValueError('Texture escapes scene directory')
                expected=mat['width']*mat['height']*8
                if expected>128*1024*1024 or texture.stat().st_size!=expected:raise ValueError('Invalid texture size')
                rgba=array.array('H');rgba.frombytes(texture.read_bytes())
                if sys.byteorder!='little':rgba.byteswap()
                self.materials.append(dict(mat,rgba=rgba))
            self.scene=Scene(self.library,self.data)
            minimum=(U*256)();self.library.call('scene_unwrap_missing',self.scene.handle,minimum)
            for i,mat in enumerate(self.materials):
                if minimum[i]:
                    size=max(minimum[i],256);base=mat['rgba'][:4]
                    mat.update(width=size,height=size,rgba=array.array('H',base)*(size*size))
            self.renderer=Renderer(self.library,self.scene,self.materials,self.data.get('environment',[.5,.5,.5]),width,height)
        except BaseException:
            self.close();raise
    def close(self):
        for surface in self.surfaces.values():surface.close()
        self.surfaces.clear()
        if self.renderer:self.renderer.close()
        if self.scene:self.scene.close()
    def frame(self,*,traced=False,samples=8):
        return self.renderer.render(self.camera,traced=traced,samples=samples,light=self.data.get('light',[-.5,1,.5,3]),exposure=self.data.get('exposure',1),filmic=self.data.get('filmic',True))
    def paint(self,u,v,color=(.8,.05,.03),brush=None,channel=0):
        hit=self.scene.pick(self.camera,u,v,self.renderer.width/self.renderer.height)
        if hit is None:return False
        material=hit.material
        if material not in self.surfaces:
            mat=self.materials[material];self.surfaces[material]=Surface(self.library,mat['width'],mat['height'],mat['rgba'],mat.get('roughness',.5),mat.get('metallic',0.))
        surface=self.surfaces[material];b=brush or Brush()
        self.library.call('surface_stamp_world',surface.handle,self.scene.handle,material,surface.layer,channel,F3(*color),hit.point,hit.normal,self.camera.eye(),C.byref(b))
        if channel==4:self.library.call('material_height',self.renderer.handle,material,.02)
        self.library.call('sync_surface',self.renderer.handle,material,surface.handle);self.history.append(material);self.redo_history.clear();return True
    def undo(self):
        if not self.history:return False
        material=self.history[-1];surface=self.surfaces[material]
        if not surface.undo():return False
        self.library.call('sync_surface',self.renderer.handle,material,surface.handle);self.history.pop();self.redo_history.append(material);return True
    def redo(self):
        if not self.redo_history:return False
        material=self.redo_history[-1];surface=self.surfaces[material]
        if not surface.redo():return False
        self.library.call('sync_surface',self.renderer.handle,material,surface.handle);self.redo_history.pop();self.history.append(material);return True

def display_png(width,height,rgba):
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
    rows=b''.join(b'\0'+rgba[y*width*4:(y+1)*width*4] for y in range(height))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows,1))+chunk(b'IEND',b'')
