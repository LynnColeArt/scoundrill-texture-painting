#include "hamudi.h"
#include <assert.h>
#include <stdlib.h>
int main(void) {
    assert(hamudi_abi_version()==1);
    HamudiHandle h=0;
    assert(hamudi_surface_create(64,64,&h)==0);
    uint32_t layer;
    assert(hamudi_surface_add_layer(h,"makeup",6,&layer)==0);
    float color[3]={1,0,0}; float points[4]={.4f,.5f,.6f,.5f};
    HamudiBrush brush={.1f,.8f,1,.15f,0,0};
    assert(hamudi_surface_stroke_uv(h,layer,0,color,1,0,points,2,&brush)==0);
    uint16_t *image=calloc(64*64*4,sizeof(uint16_t)); assert(image);
    assert(hamudi_surface_read(h,0,image,64*64*4)==0);
    assert(image[(32*64+32)*4]>60000);
    assert(hamudi_surface_undo(h)==0);
    assert(hamudi_surface_read(h,0,image,64*64*4)==0);
    assert(image[(32*64+32)*4]==32768);
    assert(hamudi_surface_redo(h)==0);
    uint64_t revision, gesture;
    assert(hamudi_surface_revision(h,&revision)==0);
    assert(hamudi_surface_begin(h,revision,layer,0,color,1,0,&gesture)==0);
    uint16_t alpha_pixels[2]={0,65535};
    HamudiAlphaImage alpha={2,1,alpha_pixels,2};
    assert(hamudi_surface_stamp_image_uv(h,gesture,.5f,.5f,1,&brush,&alpha)==0);
    assert(hamudi_surface_commit(h,gesture)==0);
    assert(hamudi_surface_cancel(h,gesture)<0);
    float positions[9]={0,0,0,1,0,0,0,1,0};
    float normals[9]={0,0,1,0,0,1,0,0,1};
    float uvs[6]={0,0,1,0,0,1}; uint32_t indices[3]={0,1,2};
    HamudiMesh mesh={positions,normals,uvs,indices,NULL,3,3};
    HamudiHandle scene=0; assert(hamudi_scene_create(&mesh,&scene)==0);
    HamudiCancel cancel={0}; HamudiBakeOptions bake={8,1,1e-5f,&cancel};
    assert(hamudi_bake(scene,0,64,64,3,&bake,image,64*64*4)==0);
    assert(image[0]==65535 && image[3]==65535);
    uint32_t baked_layer;
    assert(hamudi_surface_import_channel(h,"baked AO",8,1,image,64*64*4,&baked_layer)==0);
    assert(hamudi_surface_read(h,1,image,64*64*4)==0);
    assert(image[0]==65535);
    assert(hamudi_surface_undo(h)==0);
    assert(hamudi_surface_read(h,1,image,64*64*4)==0);
    assert(image[0]==32768);
    size_t project_size=0;
    assert(hamudi_surface_save(h,NULL,0,&project_size)==0 && project_size>16);
    uint8_t *project=malloc(project_size);assert(project);
    assert(hamudi_surface_save(h,project,project_size,&project_size)==0);
    assert(project[0]=='H' && project[7]=='2');
    assert(hamudi_surface_load(h,project,project_size)==0);
    project[project_size-1]^=1;
    assert(hamudi_surface_load(h,project,project_size)<0);
    free(project);
    assert(hamudi_cancel_set(&cancel,1)==0);
    assert(hamudi_bake(scene,0,64,64,3,&bake,image,64*64*4)<0);
    assert(image[0]==32768); /* Failed/cancelled work does not alter caller output. */
    assert(hamudi_release(scene)==0);
    assert(hamudi_release(h)==0);
    assert(hamudi_release(h)<0);
    assert(hamudi_surface_read(h,0,image,64*64*4)<0);
    assert(hamudi_surface_create(0,64,&h)<0);
    free(image); return 0;
}
