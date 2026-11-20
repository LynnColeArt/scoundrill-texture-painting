#ifndef HAMUDI_H
#define HAMUDI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1. Arrays are borrowed only for the duration of a call. Handles are
   generation checked; release invalidates them. Calls are serialized internally.
   Output memory belongs to the caller. Zero means success, negative means error.
   All nonzero-length pointers must reference valid, suitably aligned memory. */
typedef uint64_t HamudiHandle;
typedef struct {
    const float *positions, *normals, *uvs;
    const uint32_t *indices, *materials;
    size_t vertex_count, index_count;
} HamudiMesh;
typedef struct {
    uint32_t width, height;
    const uint16_t *rgba;
    float base[3], opacity, roughness, metallic, emissive[3];
} HamudiMaterial;
typedef struct {
    float target[3], yaw, pitch, distance, fov, scene_radius;
    uint32_t ortho;
} HamudiCamera;
typedef struct { float radius, hardness, flow, spacing, angle; uint32_t alpha; } HamudiBrush;
typedef struct { float point[3], normal[3], uv[2]; uint32_t triangle, material; } HamudiHit;
uint32_t hamudi_abi_version(void);
const char *hamudi_last_error(void);
int hamudi_renderer_create(HamudiHandle *out);
int hamudi_surface_create(uint32_t width, uint32_t height, HamudiHandle *out);
int hamudi_release(HamudiHandle handle);
int hamudi_set_mesh(HamudiHandle handle, const HamudiMesh *mesh);
int hamudi_set_materials(HamudiHandle handle, const HamudiMaterial *materials, size_t count);
int hamudi_set_environment(HamudiHandle handle, const float rgb[3]);
int hamudi_resize(HamudiHandle handle, uint32_t width, uint32_t height);
int hamudi_preview(HamudiHandle handle, const HamudiCamera *camera, const float light[4], float exposure, uint32_t filmic, uint8_t *rgba, size_t bytes);
int hamudi_trace(HamudiHandle handle, const HamudiCamera *camera, uint32_t samples, float exposure, uint32_t filmic, uint8_t *rgba, size_t bytes);
int hamudi_update_region(HamudiHandle handle, uint32_t material, uint32_t x, uint32_t y, uint32_t width, uint32_t height, const uint16_t *rgba);
int hamudi_surface_add_layer(HamudiHandle handle, const char *name, size_t name_bytes, uint32_t *index);
/* Channels use the declaration order in src/painting.zig; base color = 0. */
int hamudi_surface_stroke_uv(HamudiHandle handle, uint32_t layer, uint32_t channel, const float rgb[3], float opacity, uint32_t erase, const float *uvs, size_t count, const HamudiBrush *brush);
int hamudi_surface_read(HamudiHandle handle, uint32_t channel, uint16_t *rgba, size_t components);
int hamudi_surface_undo(HamudiHandle handle);
int hamudi_surface_redo(HamudiHandle handle);
int hamudi_scene_create(const HamudiMesh *mesh, HamudiHandle *out);
int hamudi_set_scene(HamudiHandle renderer, HamudiHandle scene);
int hamudi_pick(HamudiHandle scene, const HamudiCamera *camera, float u, float v, float aspect, HamudiHit *out);
int hamudi_surface_import_base(HamudiHandle surface, const uint16_t *rgba, size_t components);
int hamudi_surface_stamp_world(HamudiHandle surface, HamudiHandle scene, uint32_t material, uint32_t layer, uint32_t channel, const float color[3], const float point[3], const float normal[3], const float eye[3], const HamudiBrush *brush);
int hamudi_sync_surface(HamudiHandle renderer, uint32_t material, HamudiHandle surface);
int hamudi_surface_clear_dirty(HamudiHandle surface);
int hamudi_surface_save(HamudiHandle surface, uint8_t *out, size_t bytes, size_t *required);
int hamudi_surface_load(HamudiHandle surface, const uint8_t *data, size_t bytes);
int hamudi_surface_png(HamudiHandle surface, uint32_t channel, uint32_t bits, uint32_t color, uint8_t *out, size_t bytes, size_t *required);
int hamudi_surface_set_default(HamudiHandle surface, uint32_t channel, const float value[3]);
int hamudi_material_height(HamudiHandle renderer, uint32_t material, float strength);
int hamudi_scene_unwrap_missing(HamudiHandle scene, uint32_t minimum_resolution[256]);
#ifdef __cplusplus
}
#endif
#endif
