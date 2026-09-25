#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Returns the determinant of a 2x2 matrix.
static inline __attribute__((always_inline))
float spvDet2x2(float a1, float a2, float b1, float b2)
{
    return a1 * b2 - b1 * a2;
}

// Returns the inverse of a matrix, by using the algorithm of calculating the classical
// adjoint and dividing by the determinant. The contents of the matrix are changed.
static inline __attribute__((always_inline))
float3x3 spvInverse3x3(float3x3 m)
{
    float3x3 adj;	// The adjoint matrix (inverse after dividing by determinant)

    // Create the transpose of the cofactors, as the classical adjoint of the matrix.
    adj[0][0] =  spvDet2x2(m[1][1], m[1][2], m[2][1], m[2][2]);
    adj[0][1] = -spvDet2x2(m[0][1], m[0][2], m[2][1], m[2][2]);
    adj[0][2] =  spvDet2x2(m[0][1], m[0][2], m[1][1], m[1][2]);

    adj[1][0] = -spvDet2x2(m[1][0], m[1][2], m[2][0], m[2][2]);
    adj[1][1] =  spvDet2x2(m[0][0], m[0][2], m[2][0], m[2][2]);
    adj[1][2] = -spvDet2x2(m[0][0], m[0][2], m[1][0], m[1][2]);

    adj[2][0] =  spvDet2x2(m[1][0], m[1][1], m[2][0], m[2][1]);
    adj[2][1] = -spvDet2x2(m[0][0], m[0][1], m[2][0], m[2][1]);
    adj[2][2] =  spvDet2x2(m[0][0], m[0][1], m[1][0], m[1][1]);

    // Calculate the determinant as a combination of the cofactors of the first row.
    float det = (adj[0][0] * m[0][0]) + (adj[0][1] * m[1][0]) + (adj[0][2] * m[2][0]);

    // Divide the classical adjoint matrix by the determinant.
    // If determinant is zero, matrix is not invertable, so leave it unchanged.
    return (det != 0.0f) ? (adj * (1.0f / det)) : m;
}

struct main0_out
{
    float3 v_TexCoord [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float3x3 squareToQuad(thread const float2& p0, thread const float2& p1, thread const float2& p2, thread const float2& p3)
{
    float3x3 m = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0));
    float dx0 = p0.x;
    float dy0 = p0.y;
    float dx1 = p1.x;
    float dy1 = p1.y;
    float dx2 = p3.x;
    float dy2 = p3.y;
    float dx3 = p2.x;
    float dy3 = p2.y;
    float diffx1 = dx1 - dx3;
    float diffy1 = dy1 - dy3;
    float diffx2 = dx2 - dx3;
    float diffy2 = dy2 - dy3;
    float det = (diffx1 * diffy2) - (diffx2 * diffy1);
    float sumx = ((dx0 - dx1) + dx3) - dx2;
    float sumy = ((dy0 - dy1) + dy3) - dy2;
    bool _96 = det == 0.0;
    bool _105;
    if (!_96)
    {
        _105 = (sumx == 0.0) && (sumy == 0.0);
    }
    else
    {
        _105 = _96;
    }
    if (_105)
    {
        m[0].x = dx1 - dx0;
        m[0].y = dy1 - dy0;
        m[0].z = 0.0;
        m[1].x = dx3 - dx1;
        m[1].y = dy3 - dy1;
        m[1].z = 0.0;
        m[2].x = dx0;
        m[2].y = dy0;
        m[2].z = 1.0;
        return m;
    }
    else
    {
        float ovdet = 1.0 / det;
        float g = ((sumx * diffy2) - (diffx2 * sumy)) * ovdet;
        float h = ((diffx1 * sumy) - (sumx * diffy1)) * ovdet;
        m[0].x = (dx1 - dx0) + (g * dx1);
        m[0].y = (dy1 - dy0) + (g * dy1);
        m[0].z = g;
        m[1].x = (dx2 - dx0) + (h * dx2);
        m[1].y = (dy2 - dy0) + (h * dy2);
        m[1].z = h;
        m[2].x = dx0;
        m[2].y = dy0;
        m[2].z = 1.0;
        return m;
    }
}

vertex main0_out main0(main0_in in [[stage_in]], constant float2& g_Point0 [[buffer(0)]], constant float2& g_Point1 [[buffer(1)]], constant float2& g_Point2 [[buffer(2)]], constant float2& g_Point3 [[buffer(3)]], constant float4x4& g_ModelViewProjectionMatrix [[buffer(4)]])
{
    main0_out out = {};
    float2 param = g_Point0;
    float2 param_1 = g_Point1;
    float2 param_2 = g_Point2;
    float2 param_3 = g_Point3;
    float3x3 xform = spvInverse3x3(squareToQuad(param, param_1, param_2, param_3));
    out.v_TexCoord = float3(in.a_TexCoord, 1.0) * xform;
    out.gl_Position = float4(in.a_Position, 1.0) * g_ModelViewProjectionMatrix;
    return out;
}

