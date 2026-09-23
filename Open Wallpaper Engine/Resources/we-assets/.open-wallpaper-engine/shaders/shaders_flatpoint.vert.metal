#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 v_Color [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float4 a_PositionVec4 [[attribute(0)]];
    float4 a_Color [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    out.gl_Position = in.a_PositionVec4;
    out.v_Color = in.a_Color;
    return out;
}

