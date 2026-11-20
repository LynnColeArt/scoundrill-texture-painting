#ifndef HAMUDI_H
#define HAMUDI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1. Arrays are borrowed only for the duration of a call. Handles are
   generation checked; release invalidates them. Handle calls are serialized;
   cancellation-flag writes may run concurrently.
   Output memory belongs to the caller. Zero means success, negative means error.
   All nonzero-length pointers must reference valid, suitably aligned memory. */
typedef uint64_t HamudiHandle;
typedef enum {
    HAMUDI_BASE_COLOR, HAMUDI_ROUGHNESS, HAMUDI_METALLIC, HAMUDI_NORMAL,
    HAMUDI_HEIGHT, HAMUDI_OPACITY, HAMUDI_AMBIENT_OCCLUSION, HAMUDI_EMISSIVE,
    HAMUDI_SPECULAR_LEVEL, HAMUDI_GLOSSINESS, HAMUDI_SPECULAR, HAMUDI_COAT_WEIGHT,
    HAMUDI_COAT_ROUGHNESS, HAMUDI_ANISOTROPY_LEVEL, HAMUDI_ANISOTROPY_ANGLE,
    HAMUDI_SHEEN_COLOR, HAMUDI_SHEEN_WEIGHT, HAMUDI_SHEEN_ROUGHNESS,
    HAMUDI_COAT_NORMAL, HAMUDI_SCATTER_WEIGHT, HAMUDI_TRANSMISSION
} HamudiChannel;
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
/* Procedural alpha: round=0, square=1, star=2, grunge=3, spray=4, cloud=5,
   dry streaks=6. Custom alpha data is linear grayscale, borrowed for a call. */
typedef struct { uint32_t width, height; const uint16_t *pixels; size_t count; } HamudiAlphaImage;
/* Initialize before sharing between threads. Mutate only with cancel_set. */
typedef struct { uint32_t value; } HamudiCancel;
typedef struct { uint32_t samples; float distance, epsilon; const HamudiCancel *cancel; } HamudiBakeOptions;
typedef struct { float light[4], color[3], exposure; uint32_t filmic, shadows; float environment_opacity; } HamudiPreviewOptions;
typedef struct { float point[3], normal[3], uv[2]; uint32_t triangle, material; } HamudiHit;
uint32_t hamudi_abi_version(void);
const char *hamudi_last_error(void);
int hamudi_renderer_create(HamudiHandle *out);
/* device: 0 = prefer hardware, 1 = require hardware, 2 = require CPU Vulkan.
   CPU execution uses the same recovered shader transport through a CPU driver. */
int hamudi_renderer_create_device(uint32_t device, HamudiHandle *out);
int hamudi_surface_create(uint32_t width, uint32_t height, HamudiHandle *out);
int hamudi_release(HamudiHandle handle);
int hamudi_set_mesh(HamudiHandle handle, const HamudiMesh *mesh);
int hamudi_set_materials(HamudiHandle handle, const HamudiMaterial *materials, size_t count);
int hamudi_set_environment(HamudiHandle handle, const float rgb[3]);
int hamudi_resize(HamudiHandle handle, uint32_t width, uint32_t height);
int hamudi_preview(HamudiHandle handle, const HamudiCamera *camera, const float light[4], float exposure, uint32_t filmic, uint8_t *rgba, size_t bytes);
int hamudi_preview_options(HamudiHandle handle, const HamudiCamera *camera, const HamudiPreviewOptions *options, uint8_t *rgba, size_t bytes);
int hamudi_trace(HamudiHandle handle, const HamudiCamera *camera, uint32_t samples, float exposure, uint32_t filmic, uint8_t *rgba, size_t bytes);
int hamudi_trace_step(HamudiHandle handle, const HamudiCamera *camera, uint32_t samples);
int hamudi_resolve(HamudiHandle handle, float exposure, uint32_t filmic, uint8_t *rgba, size_t bytes);
int hamudi_reset(HamudiHandle handle);
/* Workflow is renderer-wide, matching upstream. Re-sync authoring surfaces after
   changing it so glossiness is converted to packed roughness. */
int hamudi_set_specular_glossiness(HamudiHandle handle, uint32_t enabled);
int hamudi_update_region(HamudiHandle handle, uint32_t material, uint32_t x, uint32_t y, uint32_t width, uint32_t height, const uint16_t *rgba);
int hamudi_surface_add_layer(HamudiHandle handle, const char *name, size_t name_bytes, uint32_t *index);
/* Channels use the declaration order in src/painting.zig; base color = 0. */
int hamudi_surface_stroke_uv(HamudiHandle handle, uint32_t layer, uint32_t channel, const float rgb[3], float opacity, uint32_t erase, const float *uvs, size_t count, const HamudiBrush *brush);
int hamudi_surface_read(HamudiHandle handle, uint32_t channel, uint16_t *rgba, size_t components);
int hamudi_surface_undo(HamudiHandle handle);
int hamudi_surface_redo(HamudiHandle handle);
int hamudi_scene_create(const HamudiMesh *mesh, HamudiHandle *out);
int hamudi_set_scene(HamudiHandle renderer, HamudiHandle scene);
/* Fixed-topology deformation preserves UVs and material assignments. Upload the
   updated scene to each renderer with hamudi_set_scene. */
int hamudi_scene_deform(HamudiHandle scene, const float *positions, const float *normals, size_t vertex_count);
int hamudi_pick(HamudiHandle scene, const HamudiCamera *camera, float u, float v, float aspect, HamudiHit *out);
int hamudi_surface_import_base(HamudiHandle surface, const uint16_t *rgba, size_t components);
int hamudi_surface_import_channel(HamudiHandle surface, const char *name, size_t name_bytes, uint32_t channel, const uint16_t *rgba, size_t components, uint32_t *layer);
int hamudi_surface_stamp_world(HamudiHandle surface, HamudiHandle scene, uint32_t material, uint32_t layer, uint32_t channel, const float color[3], const float point[3], const float normal[3], const float eye[3], const HamudiBrush *brush);
int hamudi_sync_surface(HamudiHandle renderer, uint32_t material, HamudiHandle surface);
int hamudi_surface_clear_dirty(HamudiHandle surface);
int hamudi_surface_save(HamudiHandle surface, uint8_t *out, size_t bytes, size_t *required);
int hamudi_surface_load(HamudiHandle surface, const uint8_t *data, size_t bytes);
int hamudi_surface_png(HamudiHandle surface, uint32_t channel, uint32_t bits, uint32_t color, uint8_t *out, size_t bytes, size_t *required);
int hamudi_surface_set_default(HamudiHandle surface, uint32_t channel, const float value[3]);
int hamudi_material_height(HamudiHandle renderer, uint32_t material, float strength);
int hamudi_scene_unwrap_missing(HamudiHandle scene, uint32_t minimum_resolution[256]);
int hamudi_surface_revision(HamudiHandle surface, uint64_t *revision);
int hamudi_surface_begin(HamudiHandle surface, uint64_t expected_revision, uint32_t layer, uint32_t channel, const float color[3], float opacity, uint32_t erase, uint64_t *gesture);
int hamudi_surface_stamp_uv(HamudiHandle surface, uint64_t gesture, float u, float v, float pressure, const HamudiBrush *brush);
int hamudi_surface_stamp_image_uv(HamudiHandle surface, uint64_t gesture, float u, float v, float pressure, const HamudiBrush *brush, const HamudiAlphaImage *image);
int hamudi_surface_stamp_image_world(HamudiHandle surface, uint64_t gesture, HamudiHandle scene, uint32_t material, const float point[3], const float normal[3], const float eye[3], const HamudiBrush *brush, const HamudiAlphaImage *image);
int hamudi_surface_stamp_world_active(HamudiHandle surface, uint64_t gesture, HamudiHandle scene, uint32_t material, const float point[3], const float normal[3], const float eye[3], const HamudiBrush *brush);
int hamudi_surface_preview(HamudiHandle renderer, uint32_t material, HamudiHandle surface, uint64_t gesture);
int hamudi_surface_commit(HamudiHandle surface, uint64_t gesture);
int hamudi_surface_cancel(HamudiHandle surface, uint64_t gesture);
int hamudi_set_environment_preset(HamudiHandle renderer, const char *name, size_t name_bytes, uint32_t width);
int hamudi_set_environment_image(HamudiHandle renderer, uint32_t width, uint32_t height, const float *rgb, size_t components);
int hamudi_set_environment_rotation(HamudiHandle renderer, float radians);
int hamudi_cancel_set(HamudiCancel *cancel, uint32_t value);
/* Maps: world normal=0, position=1, ID=2, AO=3, bent normal=4, thickness=5,
   curvature=6, height=7, tangent normal=8. Output is linear RGBA16. */
int hamudi_bake(HamudiHandle scene, uint32_t material, uint32_t width, uint32_t height, uint32_t kind, const HamudiBakeOptions *options, uint16_t *rgba, size_t components);
int hamudi_bake_transfer(HamudiHandle low, HamudiHandle high, uint32_t material, uint32_t width, uint32_t height, const HamudiBakeOptions *options, uint16_t *normal_rgba, size_t normal_components, uint16_t *heights, size_t height_components);
#ifdef __cplusplus
}
#endif
#endif
