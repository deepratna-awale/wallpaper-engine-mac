#include "ShaderToolchain.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "glslang/Public/ShaderLang.h"
#include "glslang/Public/ResourceLimits.h"
#include "SPIRV/GlslangToSpv.h"

#include "spirv_msl.hpp"
#include "spirv_parser.hpp"
#include "spirv_reflect.hpp"

// The SPIRV-Cross release the sources in ../../SPIRV-Cross were taken from (it has no runtime
// version query). Keep in sync with README.md.
#define OWE_SPIRV_CROSS_VERSION "vulkan-sdk-1.4.357.0"
// The fixed options below; change this string whenever they change.
#define OWE_SHADER_OPTIONS "E:none;G:opengl450-spv1.0-msgspv;msl20300+decoration-binding;vert:fixup-clipspace+flip-vert-y"

namespace {

std::mutex &compileLock() {
    static std::mutex lock;
    return lock;
}

void initializeOnce() {
    // Never finalized: the library stays usable for the life of the process.
    static std::once_flag once;
    std::call_once(once, [] { glslang::InitializeProcess(); });
}

char *copy(const std::string &text) {
    char *result = static_cast<char *>(std::malloc(text.size() + 1));
    if (result) std::memcpy(result, text.c_str(), text.size() + 1);
    return result;
}

EShLanguage language(owe_shader_stage stage) {
    return stage == OWE_SHADER_STAGE_VERTEX ? EShLangVertex : EShLangFragment;
}

// glslangValidator's DirStackFileIncluder with no directories: WE sources have their includes
// inlined before they get here, so every #include fails, as it does for the command line tool.
class NoIncluder : public glslang::TShader::Includer {
public:
    IncludeResult *includeSystem(const char *, const char *, size_t) override { return nullptr; }
    IncludeResult *includeLocal(const char *, const char *, size_t) override { return nullptr; }
    void releaseInclude(IncludeResult *) override {}
};

// glslangValidator names its input by file path; the scratch file was always "shader.<stage>".
const char *fileName(owe_shader_stage stage) {
    return stage == OWE_SHADER_STAGE_VERTEX ? "shader.vert" : "shader.frag";
}

std::string infoLog(glslang::TShader &shader) {
    return std::string(shader.getInfoLog()) + shader.getInfoDebugLog();
}

// StandAlone.cpp: `-E` sets no client, messages = EShMsgOnlyPreprocessor, default version 100.
bool preprocess(const char *source, owe_shader_stage stage, std::string &output, std::string &log) {
    glslang::TShader shader(language(stage));
    const char *strings[] = {source};
    const char *names[] = {fileName(stage)};
    shader.setStringsWithLengthsAndNames(strings, nullptr, names, 1);
    shader.setPreamble("");
    NoIncluder includer;
    std::string text;
    bool ok = shader.preprocess(GetDefaultResources(), 100, ENoProfile, false, false,
                                EShMsgOnlyPreprocessor, &text, includer);
    log = infoLog(shader);
    // glslangValidator prints the result with puts(), which appends a newline.
    if (ok && !text.empty()) output = text + "\n";
    return ok;
}

// StandAlone.cpp: `-G` = OpenGL client 4.50, SPIR-V 1.0, messages = EShMsgSpvRules, a linked
// program, mapIO(), then GlslangToSpv with default options.
bool compileSpirv(const char *source, owe_shader_stage stage, std::vector<unsigned int> &spirv, std::string &log) {
    EShLanguage lang = language(stage);
    glslang::TShader shader(lang);
    const char *strings[] = {source};
    const char *names[] = {fileName(stage)};
    shader.setStringsWithLengthsAndNames(strings, nullptr, names, 1);
    shader.setPreamble("");
    shader.setEnvInput(glslang::EShSourceGlsl, lang, glslang::EShClientOpenGL, 100);
    shader.setEnvClient(glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    NoIncluder includer;
    const EShMessages messages = EShMsgSpvRules;
    if (!shader.parse(GetDefaultResources(), 100, false, messages, includer)) {
        log = infoLog(shader);
        return false;
    }
    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages) || !program.mapIO()) {
        log = infoLog(shader) + program.getInfoLog() + program.getInfoDebugLog();
        return false;
    }
    glslang::SpvOptions options;
    options.compilerSignature = "glslang";
    spv::SpvBuildLogger logger;
    glslang::GlslangToSpv(*program.getIntermediate(lang), spirv, &logger, &options);
    return true;
}

// spirv-cross main.cpp `compile_iteration` with the CLI defaults and our three flags.
std::string compileMSL(std::vector<uint32_t> spirv, owe_shader_stage stage) {
    using namespace SPIRV_CROSS_NAMESPACE;
    Parser parser(std::move(spirv));
    parser.parse();
    CompilerMSL compiler(std::move(parser.get_parsed_ir()));

    auto msl = compiler.get_msl_options();
    msl.msl_version = 20300;
    msl.capture_output_to_buffer = false;
    msl.swizzle_texture_samples = false;
    msl.invariant_float_math = false;
    msl.pad_fragment_output_components = false;
    msl.tess_domain_origin_lower_left = false;
    msl.argument_buffers = false;
    msl.argument_buffers_tier = CompilerMSL::Options::ArgumentBuffersTier::Tier1;
    msl.texture_buffer_native = false;
    msl.multiview = false;
    msl.multiview_layered_rendering = true;
    msl.view_index_from_device_index = false;
    msl.dispatch_base = false;
    msl.enable_decoration_binding = true;
    msl.force_active_argument_buffer_resources = false;
    msl.force_native_arrays = false;
    msl.enable_frag_depth_builtin = true;
    msl.enable_frag_stencil_ref_builtin = true;
    msl.enable_frag_output_mask = 0xffffffff;
    msl.enable_clip_distance_user_varying = true;
    msl.raw_buffer_tese_input = false;
    msl.multi_patch_workgroup = false;
    msl.vertex_for_tessellation = false;
    msl.additional_fixed_sample_mask = 0xffffffff;
    msl.arrayed_subpass_input = false;
    msl.r32ui_linear_texture_alignment = 4;
    msl.r32ui_alignment_constant_id = 65535;
    msl.texture_1D_as_2D = false;
    msl.ios_use_simdgroup_functions = false;
    msl.emulate_subgroups = false;
    msl.fixed_subgroup_size = 0;
    msl.force_sample_rate_shading = false;
    msl.manual_helper_invocation_updates = true;
    msl.check_discarded_frag_stores = false;
    msl.force_fragment_with_side_effects_execution = false;
    msl.emulate_reversed_depth_viewport = false;
    msl.sample_dref_lod_array_as_grad = false;
    msl.ios_support_base_vertex_instance = true;
    msl.runtime_array_rich_descriptor = false;
    msl.replace_recursive_inputs = false;
    msl.input_attachment_is_ds_attachment = false;
    msl.readwrite_texture_fences = true;
    msl.agx_manual_cube_grad_fixup = false;
    msl.disable_rasterization = false;
    msl.auto_disable_rasterization = false;
    msl.enable_point_size_default = false;
    msl.default_point_size = 1.0f;
    compiler.set_msl_options(msl);

    auto common = compiler.get_common_options();
    common.force_temporary = false;
    common.separate_shader_objects = false;
    common.flatten_multidimensional_arrays = false;
    common.enable_420pack_extension = true;
    common.vulkan_semantics = false;
    common.vertex.fixup_clipspace = stage == OWE_SHADER_STAGE_VERTEX;
    common.vertex.flip_vert_y = stage == OWE_SHADER_STAGE_VERTEX;
    common.vertex.support_nonzero_base_instance = true;
    common.emit_push_constant_as_uniform_buffer = false;
    common.emit_uniform_buffer_as_plain_uniforms = false;
    common.force_flattened_io_blocks = false;
    common.ovr_multiview_view_count = 0;
    common.emit_line_directives = false;
    common.enable_storage_image_qualifier_deduction = true;
    common.force_zero_initialized_variables = false;
    common.relax_nan_checks = false;
    common.force_recompile_max_debug_iterations = 3;
    compiler.set_common_options(common);

    // Mirrors the CLI, which queries resources and remaps (no) pixel-local storage before compiling.
    (void)compiler.get_shader_resources();
    compiler.remap_pixel_local_storage({}, {});
    return compiler.compile();
}

std::string reflect(std::vector<uint32_t> spirv) {
    using namespace SPIRV_CROSS_NAMESPACE;
    Parser parser(std::move(spirv));
    parser.parse();
    CompilerReflection compiler(std::move(parser.get_parsed_ir()));
    compiler.set_format("json");
    return compiler.compile();
}

} // namespace

extern "C" int owe_shader_preprocess(const char *source, owe_shader_stage stage, char **output, char **log) {
    std::lock_guard<std::mutex> guard(compileLock());
    initializeOnce();
    std::string text, messages;
    if (!preprocess(source, stage, text, messages)) {
        *log = copy(messages);
        return 0;
    }
    *output = copy(text);
    return 1;
}

extern "C" int owe_shader_compile_msl(const char *source, owe_shader_stage stage, char **msl, char **reflection,
                                      char **log, const char **failed_step) {
    std::lock_guard<std::mutex> guard(compileLock());
    initializeOnce();
    std::vector<unsigned int> spirv;
    std::string messages;
    if (!compileSpirv(source, stage, spirv, messages)) {
        *failed_step = "glslang";
        *log = copy(messages);
        return 0;
    }
    std::vector<uint32_t> words(spirv.begin(), spirv.end());
    std::string mslText;
    try {
        mslText = compileMSL(words, stage);
    } catch (const std::exception &error) {
        *failed_step = "spirv-cross";
        *log = copy(error.what());
        return 0;
    }
    std::string json;
    try {
        json = reflect(words);
    } catch (const std::exception &error) {
        *failed_step = "reflect";
        *log = copy(error.what());
        return 0;
    }
    *msl = copy(mslText);
    *reflection = copy(json);
    return 1;
}

extern "C" void owe_shader_free(char *string) { std::free(string); }

extern "C" const char *owe_shader_toolchain_fingerprint(void) {
    static const std::string fingerprint = [] {
        auto version = glslang::GetVersion();
        return "glslang " + std::to_string(version.major) + "." + std::to_string(version.minor) + "." +
               std::to_string(version.patch) + version.flavor + "|spirv-cross " OWE_SPIRV_CROSS_VERSION
               "|" OWE_SHADER_OPTIONS;
    }();
    return fingerprint.c_str();
}
