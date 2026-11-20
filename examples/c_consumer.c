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
    assert(hamudi_release(h)==0);
    assert(hamudi_release(h)<0);
    assert(hamudi_surface_read(h,0,image,64*64*4)<0);
    assert(hamudi_surface_create(0,64,&h)<0);
    free(image); return 0;
}
