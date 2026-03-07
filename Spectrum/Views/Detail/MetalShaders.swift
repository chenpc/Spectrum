import Metal

enum MetalShaders {
    static let source: String = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle (3 vertices, no VBO needed)
vertex VertexOut vertexPassthrough(uint vid [[vertex_id]],
                                   constant uint &rotation [[buffer(0)]]) {
    VertexOut out;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    // Apply video rotation to texture coordinates
    // rotation: 0=none, 90=CW, 180=flip, 270=CCW
    float2 centered = uv - 0.5;
    if (rotation == 90u) {
        centered = float2(centered.y, -centered.x);
    } else if (rotation == 180u) {
        centered = float2(-centered.x, -centered.y);
    } else if (rotation == 270u) {
        centered = float2(-centered.y, centered.x);
    }
    out.texCoord = centered + 0.5;
    return out;
}

// --- Transfer function helpers ---

float3 pqEOTF(float3 N) {
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 Np = pow(max(N, 0.0), float3(1.0 / m2));
    return pow(max(Np - c1, 0.0) / (c2 - c3 * Np), float3(1.0 / m1));
}

float3 pqOETF(float3 L) {
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 Lm = pow(max(L, 0.0), float3(m1));
    return pow((c1 + c2 * Lm) / (1.0 + c3 * Lm), float3(m2));
}

float3 hlgEOTF(float3 E) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = (E[i] <= 0.5) ? E[i]*E[i]/3.0 : (exp((E[i]-c)/a)+b)/12.0;
    return r;
}

float3 hlgOETF(float3 L) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = (L[i] <= 1.0/12.0) ? sqrt(3.0*L[i]) : a*log(12.0*L[i]-b)+c;
    return r;
}

// --- YCbCr -> RGB fragment shader ---

fragment float4 fragmentYCbCrToRGB(VertexOut in [[stage_in]],
                                    texture2d<float> texY [[texture(0)]],
                                    texture2d<float> texCbCr [[texture(1)]],
                                    constant uint &mode [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float y  = texY.sample(s, in.texCoord).r;
    float2 cbcr = texCbCr.sample(s, in.texCoord).rg;

    if (mode == 12) return float4(y, y, y, 1.0);
    if (mode == 13) return float4(cbcr.x, cbcr.y, 0.5, 1.0);

    float Y, Cb, Cr;
    bool fullRange = (mode == 1 || mode == 3 || mode == 5 || mode == 7);
    if (fullRange) { Y = y; Cb = cbcr.x - 0.5; Cr = cbcr.y - 0.5; }
    else { Y = (y - 0.06256109) * 1.167808; Cb = (cbcr.x - 0.50048876) * 1.141685; Cr = (cbcr.y - 0.50048876) * 1.141685; }

    float3 rgb;
    if (mode <= 1 || mode >= 6) { rgb.r = Y + 1.4746*Cr; rgb.g = Y - 0.16455*Cb - 0.57135*Cr; rgb.b = Y + 1.8814*Cb; }
    else if (mode <= 3) { rgb.r = Y + 1.5748*Cr; rgb.g = Y - 0.1873*Cb - 0.4681*Cr; rgb.b = Y + 1.8556*Cb; }
    else { rgb.r = Y + 1.402*Cr; rgb.g = Y - 0.3441*Cb - 0.7141*Cr; rgb.b = Y + 1.772*Cb; }

    if (mode == 8) { float3 lin = pqEOTF(clamp(rgb, 0.0, 1.0)); return float4(clamp(hlgOETF(lin * 10.0), 0.0, 1.0), 1.0); }
    if (mode == 9) { float3 lin = hlgEOTF(clamp(rgb, 0.0, 1.0)); return float4(clamp(pqOETF(lin / 10.0), 0.0, 1.0), 1.0); }
    if (mode == 10) { return float4(pqEOTF(clamp(rgb, 0.0, 1.0)), 1.0); }
    if (mode == 11) { return float4(hlgEOTF(clamp(rgb, 0.0, 1.0)), 1.0); }
    if (mode == 6 || mode == 7) return float4(rgb, 1.0);
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// Simple BGRA passthrough
fragment float4 fragmentBGRA(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return float4(tex.sample(s, in.texCoord).rgb, 1.0);
}

// --- Warp shader (gyro stabilization) ---

struct WarpUniforms {
    float2 videoSize;
    float  matCount;
    float  _pad0;
    float2 fIn;
    float2 cIn;
    float4 distK[3];   // k[0..11] as 3 x vec4
    int    distModel;   // 0=None 1=OpenCVFisheye 3=Poly3 4=Poly5 7=Sony
    float  rLimit;
    float  frameFov;
    float  lensCorr;
};

// Lens undistort (Newton-Raphson inverse)
float2 undistort_point(float2 pos, int distModel, constant float4 *distK) {
    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta_d = clamp(length(pos), -1.5707963, 1.5707963);
        float theta = theta_d;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t6*t2;
                float theta_fix = (theta*(1.0+distK[0].x*t2+distK[0].y*t4+distK[0].z*t6+distK[0].w*t8) - theta_d)
                                / (1.0+3.0*distK[0].x*t2+5.0*distK[0].y*t4+7.0*distK[0].z*t6+9.0*distK[0].w*t8);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) break;
            }
            float scale = tan(theta) / theta_d;
            if ((theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0)) return float2(0.0);
            return pos * scale;
        }
        return pos;
    }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = float2(1.0);
        float2 p = pos / post_scale;
        float theta_d = length(p); float theta = theta_d;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t3 = t2*theta; float t4 = t2*t2; float t5 = t4*theta;
                float theta_fix = (theta*(distK[0].x+distK[0].y*theta+distK[0].z*t2+distK[0].w*t3+distK[1].x*t4+distK[1].y*t5) - theta_d)
                                / (distK[0].x+2.0*distK[0].y*theta+3.0*distK[0].z*t2+4.0*distK[0].w*t3+5.0*distK[1].x*t4+6.0*distK[1].y*t5);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) break;
            }
            float scale = tan(theta) / theta_d;
            if ((theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0)) return float2(0.0);
            return p * scale;
        }
        return p;
    }
    return pos;
}

// Lens distortion: 3D homogeneous -> 2D distorted normalized coords
float2 distort_point(float x, float y, float w, int distModel, constant float4 *distK, float rLimit) {
    float2 pos = float2(x, y) / w;
    if (distModel == 0) return pos;
    float r = length(pos);
    if (rLimit > 0.0 && r > rLimit) return float2(-99999.0);

    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t4*t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        return pos * ((r == 0.0) ? 1.0 : theta_d / r);
    }
    if (distModel == 3) { return pos * (distK[0].x * (pos.x*pos.x + pos.y*pos.y) + 1.0); }
    if (distModel == 4) { float r2 = pos.x*pos.x + pos.y*pos.y; return pos * (1.0 + distK[0].x*r2 + distK[0].y*r2*r2); }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta*theta; float t3 = t2*theta; float t4 = t2*t2; float t5 = t4*theta; float t6 = t3*t3;
        float theta_d = distK[0].x*theta + distK[0].y*t2 + distK[0].z*t3 + distK[0].w*t4 + distK[1].x*t5 + distK[1].y*t6;
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        float2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = float2(1.0);
        return pos * scale * post_scale;
    }
    return pos;
}

float2 rotate_and_distort(float2 out_px, float texY, texture2d<float> matTex, constant WarpUniforms &u) {
    constexpr sampler ms(filter::nearest, address::clamp_to_edge);
    float4 m0 = matTex.sample(ms, float2(0.125, texY));
    float4 m1 = matTex.sample(ms, float2(0.375, texY));
    float4 m2 = matTex.sample(ms, float2(0.625, texY));
    float4 m3 = matTex.sample(ms, float2(0.875, texY));

    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return float2(-99999.0);

    float2 dp = distort_point(_x, _y, _w, u.distModel, u.distK, u.rLimit);
    if (dp.x < -99998.0) return dp;
    float2 pt = u.fIn * dp;

    float sx = m0.a, sy = m1.a, ra = m2.a;
    float ox = m3.r, oy = m3.g;
    if (sx != 0.0 || sy != 0.0 || ra != 0.0 || ox != 0.0 || oy != 0.0) {
        float cos_a = cos(-ra), sin_a = sin(-ra);
        pt = float2(cos_a*pt.x - sin_a*pt.y - sx + ox,
                     sin_a*pt.x + cos_a*pt.y - sy + oy);
    }
    return pt + u.cIn;
}

fragment float4 fragmentWarp(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              texture2d<float> matTex [[texture(1)]],
                              constant WarpUniforms &u [[buffer(0)]]) {
    constexpr sampler ts(filter::linear, address::clamp_to_edge);
    // Metal: texCoord (0,0) = top-left, y=0 = top row of video
    float2 out_px = float2(in.texCoord.x * u.videoSize.x, in.texCoord.y * u.videoSize.y);

    // Lens correction (undistort output coords)
    if (u.distModel != 0 && u.frameFov > 0.0 && u.lensCorr < 1.0) {
        float factor = max(1.0 - u.lensCorr, 0.001);
        float2 out_c = u.videoSize * 0.5;
        float2 out_f = u.fIn / u.frameFov / factor;
        float2 norm  = (out_px - out_c) / out_f;
        float2 corr  = undistort_point(norm, u.distModel, u.distK);
        float2 undist = corr * out_f + out_c;
        out_px = undist * (1.0 - u.lensCorr) + out_px * u.lensCorr;
    }

    float sy = clamp(out_px.y, 0.0, u.matCount - 1.0);
    if (u.matCount > 1.0) {
        float midTexY = (floor(u.matCount * 0.5) + 0.5) / u.matCount;
        float2 midPt = rotate_and_distort(out_px, midTexY, matTex, u);
        if (midPt.x > -99998.0) { sy = clamp(floor(0.5 + midPt.y), 0.0, u.matCount - 1.0); }
    }
    float texY = (sy + 0.5) / u.matCount;
    float2 src_px = rotate_and_distort(out_px, texY, matTex, u);
    if (src_px.x < -99998.0) return float4(0.0, 0.0, 0.0, 1.0);
    // Metal: texture y=0 = top, no flip needed
    float2 src = float2(src_px.x / u.videoSize.x, src_px.y / u.videoSize.y);
    src = clamp(src, float2(0.0), float2(1.0));
    return tex.sample(ts, src);
}
"""
}
