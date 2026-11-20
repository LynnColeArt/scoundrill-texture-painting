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

class AlphaImage(C.Structure):
    _fields_ = [('width',U),('height',U),('pixels',P),('count',Z)]

class BakeOptions(C.Structure):
    _fields_ = [('samples',U),('distance',C.c_float),('epsilon',C.c_float),('cancel',P)]

class PreviewOptions(C.Structure):
    _fields_ = [('light',F4),('color',F3),('exposure',C.c_float),('filmic',U),('shadows',U),('environment_opacity',C.c_float)]

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
            'surface_revision':[H,P], 'surface_begin':[H,H,U,U,P,C.c_float,U,P],
            'surface_stamp_uv':[H,H,C.c_float,C.c_float,C.c_float,P],
            'surface_stamp_world_active':[H,H,H,U,P,P,P,P], 'surface_preview':[H,U,H,H],
            'surface_commit':[H,H], 'surface_cancel':[H,H],
            'set_environment_preset':[H,P,Z,U], 'set_environment_image':[H,U,U,P,Z],
            'set_environment_rotation':[H,C.c_float],
            'scene_deform':[H,P,P,Z],
            'renderer_create_device':[U,P], 'trace_step':[H,P,U],
            'resolve':[H,C.c_float,U,P,Z], 'reset':[H],
            'set_specular_glossiness':[H,U],
            'surface_stamp_image_uv':[H,H,C.c_float,C.c_float,C.c_float,P,P],
            'surface_stamp_image_world':[H,H,H,U,P,P,P,P,P],
            'cancel_set':[P,U], 'bake':[H,U,U,U,U,P,P,Z],
            'bake_transfer':[H,H,U,U,U,P,P,Z,P,Z],
            'surface_import_channel':[H,P,Z,U,P,Z,P],
            'preview_options':[H,P,P,P,Z],
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
    data=values if isinstance(values,array.array) and values.typecode==typecode else array.array(typecode, values)
    return data, (C.c_char * (len(data)*data.itemsize)).from_buffer(data)

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
    def deform(self,positions,normals):
        if len(positions)!=len(normals):raise ValueError('Mismatched deformation arrays')
        self.deform_buffers(array.array('f',(v for p in positions for v in p)),array.array('f',(v for n in normals for v in n)))
    def deform_buffers(self,positions,normals):
        pd,pb=_buffer('f',positions);nd,nb=_buffer('f',normals)
        if len(pd)!=len(nd) or len(pd)%3:raise ValueError('Mismatched deformation arrays')
        self.library.call('scene_deform',self.handle,pb,nb,len(pd)//3)
    def bake(self,kind,width=256,height=256,material=0,samples=32,distance=1.,cancel=None):
        if not 0<width<=8192 or not 0<height<=8192 or width*height>16777216:raise ValueError('BakeBudget')
        output=(C.c_uint16*(width*height*4))();options=BakeOptions(samples,distance,1e-5,C.cast(C.byref(cancel.flag),P) if cancel else None)
        self.library.call('bake',self.handle,material,width,height,kind,C.byref(options),output,len(output))
        return array.array('H',output)

class Cancellation:
    def __init__(self,library):self.library=library;self.flag=U(0)
    def set(self,value=True):self.library.call('cancel_set',C.byref(self.flag),value)

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
    def import_channel(self,pixels,channel,name='Imported map'):
        data,buf=_buffer('H',pixels);encoded=name.encode();layer=U()
        self.library.call('surface_import_channel',self.handle,encoded,len(encoded),channel,buf,len(data),C.byref(layer));self.layer=layer.value
    def read(self,channel=0):
        out=(C.c_uint16*(self.width*self.height*4))()
        self.library.call('surface_read',self.handle,channel,out,len(out));return bytes(out)
    def undo(self): return self.library.call('surface_undo',self.handle)==0
    def redo(self): return self.library.call('surface_redo',self.handle)==0
    @property
    def revision(self):
        value=H();self.library.call('surface_revision',self.handle,C.byref(value));return value.value
    def begin(self,color=(1,0,0),channel=0,opacity=1.,erase=False,expected_revision=None):
        token=H();expected=self.revision if expected_revision is None else expected_revision
        self.library.call('surface_begin',self.handle,expected,self.layer,channel,F3(*color),opacity,erase,C.byref(token));return token.value
    def stamp_uv(self,token,u,v,brush=None,pressure=1.):
        b=brush or Brush();self.library.call('surface_stamp_uv',self.handle,token,u,v,pressure,C.byref(b))
    def stamp_image_uv(self,token,u,v,width,height,pixels,brush=None,pressure=1.):
        data,buf=_buffer('H',pixels);image=AlphaImage(width,height,C.cast(buf,P),len(data));b=brush or Brush()
        self.library.call('surface_stamp_image_uv',self.handle,token,u,v,pressure,C.byref(b),C.byref(image))
    def commit(self,token): self.library.call('surface_commit',self.handle,token)
    def cancel(self,token): self.library.call('surface_cancel',self.handle,token)
    def project(self):
        required=Z();self.library.call('surface_save',self.handle,None,0,C.byref(required))
        output=C.create_string_buffer(required.value);self.library.call('surface_save',self.handle,output,len(output),C.byref(required));return output.raw
    def load(self,data):
        self.library.call('surface_load',self.handle,data,len(data))
        row=json.loads(data[16:16+struct.unpack_from('<I',data,8)[0]]) if data.startswith(b'HAMUDI02') else json.loads(data)
        self.width=row['width'];self.height=row['height'];self.layer=len(row['layers'])-1
    def png(self,channel=0,bits=16,color=None):
        if color is None:color=channel in (0,7,10,15)
        required=Z();self.library.call('surface_png',self.handle,channel,bits,color,None,0,C.byref(required))
        output=C.create_string_buffer(required.value);self.library.call('surface_png',self.handle,channel,bits,color,output,len(output),C.byref(required));return output.raw

class Renderer(Resource):
    def __init__(self,library,scene,materials,environment=(.5,.5,.5),width=1280,height=720,environment_preset=None,device=0):
        self.library=library;self.handle=H();library.call('renderer_create_device',device,C.byref(self.handle))
        try:
            library.call('set_scene',self.handle,scene.handle)
            entries=(Material*len(materials))();keep=[]
            for entry,mat in zip(entries,materials):
                data,buf=_buffer('H',mat['rgba']);keep.extend([data,buf])
                entry.width=mat['width'];entry.height=mat['height'];entry.rgba=C.cast(buf,P);entry.base=F3(.5,.5,.5);entry.opacity=1.;entry.roughness=mat.get('roughness',.5);entry.metallic=mat.get('metallic',0);entry.emissive=F3(*mat.get('emissive',[0,0,0]))
            library.call('set_materials',self.handle,entries,len(entries))
            if environment_preset:
                name=environment_preset.encode();library.call('set_environment_preset',self.handle,name,len(name),512)
            else:library.call('set_environment',self.handle,F3(*environment))
            self.resize(width,height)
        except BaseException:
            self.close();raise
    def resize(self,width,height):
        self.library.call('resize',self.handle,width,height);self.width=width;self.height=height;self.output=(C.c_uint8*(width*height*4))()
    def render(self,camera,*,traced=False,samples=8,light=(-.5,1,.5,3),exposure=1.,filmic=True,shadows=True):
        if traced:self.library.call('trace',self.handle,C.byref(camera),samples,exposure,filmic,self.output,len(self.output))
        else:
            options=PreviewOptions(F4(*light),F3(1,1,1),exposure,filmic,shadows,1.)
            self.library.call('preview_options',self.handle,C.byref(camera),C.byref(options),self.output,len(self.output))
        return bytes(self.output)
    def progressive(self,camera,*,samples=128,exposure=1.,filmic=True,cancel=None):
        if not isinstance(samples,int) or not 1<=samples<=65536:raise ValueError('SampleBudget')
        self.library.call('reset',self.handle)
        for done in range(0,samples,8):
            if cancel and cancel():return
            self.library.call('trace_step',self.handle,C.byref(camera),min(8,samples-done))
            self.library.call('resolve',self.handle,exposure,filmic,self.output,len(self.output))
            yield min(done+8,samples),bytes(self.output)

class PreparedViewport:
    """Scoundrill prepared-scene adapter, with persistent rendering and painting."""
    def __init__(self,path,library_path=None,width=1280,height=720,paint_resolution=256):
        if type(paint_resolution) is not int or not 1<=paint_resolution<=4096:raise ValueError('PaintResolutionBudget')
        self.library=Library(library_path);self.scene=None;self.renderer=None;self.surfaces={};self.history=[];self.redo_history=[];self.active=None;self.revision=0
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
            self.generated_uv_materials=[i for i,value in enumerate(minimum) if value]
            for i,mat in enumerate(self.materials):
                if minimum[i] or mat['width']*mat['height']==1:
                    size=max(minimum[i],paint_resolution);base=mat['rgba'][:4]
                    if size>4096:raise ValueError('Generated UV charts exceed the prepared viewport budget')
                    mat.update(width=size,height=size,rgba=array.array('H',base)*(size*size))
            self.renderer=Renderer(self.library,self.scene,self.materials,self.data.get('environment',[.5,.5,.5]),width,height,self.data.get('environment_preset'))
        except BaseException:
            self.close();raise
    def close(self):
        for surface in self.surfaces.values():surface.close()
        self.surfaces.clear()
        if self.renderer:self.renderer.close()
        if self.scene:self.scene.close()
    def frame(self,*,traced=False,samples=8):
        return self.renderer.render(self.camera,traced=traced,samples=samples,light=self.data.get('light',[-.5,1,.5,3]),exposure=self.data.get('exposure',1),filmic=self.data.get('filmic',True),shadows=self.data.get('shadows',True))
    def deform(self,positions,normals):
        if self.active:raise RuntimeError('Finish the brush gesture before changing pose')
        self.scene.deform(positions,normals)
        self.library.call('set_scene',self.renderer.handle,self.scene.handle)
    def deform_buffers(self,positions,normals):
        if self.active:raise RuntimeError('Finish the brush gesture before changing pose')
        self.scene.deform_buffers(positions,normals)
        self.library.call('set_scene',self.renderer.handle,self.scene.handle)
    def paint(self,u,v,color=(.8,.05,.03),brush=None,channel=0):
        if not self.begin_paint(u,v,color,brush,channel): return False
        return self.finish_paint()
    def begin_paint(self,u,v,color=(.8,.05,.03),brush=None,channel=0,expected_revision=None):
        if self.active:raise RuntimeError('A brush gesture is already active')
        if expected_revision is not None and expected_revision!=self.revision:raise RuntimeError('StaleRevision')
        hit=self.scene.pick(self.camera,u,v,self.renderer.width/self.renderer.height)
        if hit is None:return False
        material=hit.material
        if material not in self.surfaces:
            mat=self.materials[material];self.surfaces[material]=Surface(self.library,mat['width'],mat['height'],mat['rgba'],mat.get('roughness',.5),mat.get('metallic',0.))
        surface=self.surfaces[material];b=brush or Brush();before_revision=surface.revision;token=surface.begin(color,channel)
        self.active=dict(surface=surface,material=material,token=token,brush=b,last=(u,v),before_revision=before_revision)
        try:
            self.library.call('surface_stamp_world_active',surface.handle,token,self.scene.handle,material,hit.point,hit.normal,self.camera.eye(),C.byref(b))
            self.library.call('surface_preview',self.renderer.handle,material,surface.handle,token)
        except BaseException:
            surface.cancel(token);self.active=None;self.library.call('sync_surface',self.renderer.handle,material,surface.handle);raise
        if channel==4:self.library.call('material_height',self.renderer.handle,material,.02)
        return True
    def continue_paint(self,u,v):
        if not self.active:raise RuntimeError('No active brush gesture')
        state=self.active;start=state['last'];brush=state['brush'];aspect=self.renderer.width/self.renderer.height
        length=math.hypot((u-start[0])*aspect,v-start[1]);step=max(1e-5,brush.radius*brush.spacing/(self.camera.distance*math.tan(math.radians(self.camera.fov)/2)))
        count=min(256,max(1,math.ceil(length/step)));painted=False
        for i in range(1,count+1):
            hit=self.scene.pick(self.camera,start[0]+(u-start[0])*i/count,start[1]+(v-start[1])*i/count,aspect)
            if hit is None or hit.material!=state['material']:continue
            self.library.call('surface_stamp_world_active',state['surface'].handle,state['token'],self.scene.handle,state['material'],hit.point,hit.normal,self.camera.eye(),C.byref(brush));painted=True
        state['last']=(u,v)
        if painted:self.library.call('surface_preview',self.renderer.handle,state['material'],state['surface'].handle,state['token'])
        return painted
    def finish_paint(self,cancel=False):
        if not self.active:return False
        state=self.active;surface=state['surface'];material=state['material']
        changed=False
        if cancel:surface.cancel(state['token'])
        else:
            surface.commit(state['token']);changed=surface.revision!=state['before_revision']
            if changed:self.history.append(material);self.redo_history.clear();self.revision+=1
        self.active=None;self.library.call('sync_surface',self.renderer.handle,material,surface.handle);return cancel or changed
    def undo(self):
        if not self.history:return False
        material=self.history[-1];surface=self.surfaces[material]
        if not surface.undo():return False
        self.history.pop();self.redo_history.append(material);self.revision+=1;self.library.call('sync_surface',self.renderer.handle,material,surface.handle);return True
    def redo(self):
        if not self.redo_history:return False
        material=self.redo_history[-1];surface=self.surfaces[material]
        if not surface.redo():return False
        self.redo_history.pop();self.history.append(material);self.revision+=1;self.library.call('sync_surface',self.renderer.handle,material,surface.handle);return True

def display_png(width,height,rgba):
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
    rows=b''.join(b'\0'+rgba[y*width*4:(y+1)*width*4] for y in range(height))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows,1))+chunk(b'IEND',b'')
