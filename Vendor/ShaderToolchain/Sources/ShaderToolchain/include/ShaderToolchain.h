#ifndef OWE_SHADER_TOOLCHAIN_H
#define OWE_SHADER_TOOLCHAIN_H

// In-process glslang + SPIRV-Cross, reproducing exactly what the app used to run as processes:
//   glslangValidator -E -S <stage> file                        (owe_shader_preprocess)
//   glslangValidator -G -S <stage> -o spv file                 (owe_shader_compile_msl, step 1)
//   spirv-cross spv --msl --msl-version 20300 --msl-decoration-binding
//               [--fixup-clipspace --flip-vert-y for vertex]   (step 2)
//   spirv-cross spv --reflect                                  (step 3)
//
// Every call is serialized on one internal lock: glslang keeps process-global state (symbol
// tables, the pool allocator) that is not safe to use from several threads at once.
//
// Strings returned through `char **` are heap allocated; release them with owe_shader_free.

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    OWE_SHADER_STAGE_VERTEX = 0,
    OWE_SHADER_STAGE_FRAGMENT = 1,
} owe_shader_stage;

/// Returns 1 on success with `*output` set; 0 on failure with `*log` set.
int owe_shader_preprocess(const char *source, owe_shader_stage stage, char **output, char **log);

/// Returns 1 on success with `*msl` and `*reflection` set; 0 on failure with `*log` set
/// (`*failed_step` then names the step: "glslang", "spirv-cross" or "reflect").
int owe_shader_compile_msl(const char *source, owe_shader_stage stage, char **msl, char **reflection,
                           char **log, const char **failed_step);

void owe_shader_free(char *string);

/// Identifies the linked libraries and the fixed option set; changes whenever output can.
const char *owe_shader_toolchain_fingerprint(void);

#ifdef __cplusplus
}
#endif

#endif
