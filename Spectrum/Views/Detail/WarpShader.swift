import OpenGL.GL3

// MARK: - Warp Shader Sources & Compiler

/// Namespace for gyroflow warp pipeline GLSL shaders and shader compilation.
enum WarpShader {

    // MARK: Core Profile (#version 150)

    static let vertexCore: String = """
#version 150
in vec2 pos;
out vec2 uv;
void main() {
    uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);
}
"""

    // Fragment shader: gyroflow-core pipeline with lens distortion + IBIS/OIS + RS.
    static let fragmentCore: String = """
#version 150
in vec2 uv;
out vec4 fragColor;
uniform sampler2D tex;
uniform sampler2D matTex;
uniform vec2  videoSize;
uniform float matCount;
uniform vec2  fIn;
uniform vec2  cIn;
uniform vec4  distK[3];    // k[0..11] as 3 \u{00d7} vec4
uniform int   distModel;   // 0=None 1=OpenCVFisheye 3=Poly3 4=Poly5 7=Sony
uniform float rLimit;      // radial distortion limit (0 = unlimited)
uniform float frameFov;    // per-frame FOV from adaptive zoom
uniform float lensCorr;    // lens_correction_amount (0=full undistort, 1=none)

// \u{2500}\u{2500} Lens undistort: Newton-Raphson inverse (output-space correction) \u{2500}\u{2500}
vec2 undistort_point(vec2 pos) {
    if (distModel == 1) {
        // OpenCV Fisheye inverse
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta_d = clamp(length(pos), -1.5707963, 1.5707963);
        float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t4 = t2*t2;
                float t6 = t4*t2; float t8 = t6*t2;
                float k0t2 = distK[0].x*t2; float k1t4 = distK[0].y*t4;
                float k2t6 = distK[0].z*t6; float k3t8 = distK[0].w*t8;
                float theta_fix = (theta*(1.0+k0t2+k1t4+k2t6+k3t8) - theta_d)
                                / (1.0+3.0*k0t2+5.0*k1t4+7.0*k2t6+9.0*k3t8);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return pos * scale;
        return vec2(0.0);
    }
    if (distModel == 7) {
        // Sony inverse
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        vec2 p = pos / post_scale;
        float theta_d = length(p); float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t3 = t2*theta;
                float t4 = t2*t2; float t5 = t4*theta;
                float k0 = distK[0].x; float k1t = distK[0].y*theta;
                float k2t2 = distK[0].z*t2; float k3t3 = distK[0].w*t3;
                float k4t4 = distK[1].x*t4; float k5t5 = distK[1].y*t5;
                float theta_fix = (theta*(k0+k1t+k2t2+k3t3+k4t4+k5t5) - theta_d)
                                / (k0+2.0*k1t+3.0*k2t2+4.0*k3t3+5.0*k4t4+6.0*k5t5);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return p * scale;
        return vec2(0.0);
    }
    return pos; // None/Poly: identity
}

// \u{2500}\u{2500} Lens distortion: map 3D homogeneous \u{2192} 2D distorted normalized coords \u{2500}\u{2500}
vec2 distort_point(float x, float y, float w) {
    vec2 pos = vec2(x, y) / w;
    if (distModel == 0) return pos; // None: identity
    float r = length(pos);
    if (rLimit > 0.0 && r > rLimit) return vec2(-99999.0);

    if (distModel == 1) {
        // OpenCV Fisheye: theta_d = theta * (1 + k0*t2 + k1*t4 + k2*t6 + k3*t8)
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t4 = t2 * t2;
        float t6 = t4 * t2; float t8 = t4 * t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        return pos * scale;
    }
    if (distModel == 3) {
        float poly2 = distK[0].x * (pos.x*pos.x + pos.y*pos.y) + 1.0;
        return pos * poly2;
    }
    if (distModel == 4) {
        float r2 = pos.x*pos.x + pos.y*pos.y;
        float poly4 = 1.0 + distK[0].x * r2 + distK[0].y * r2 * r2;
        return pos * poly4;
    }
    if (distModel == 7) {
        // Sony: theta_d = k0*\u{03b8} + k1*\u{03b8}\u{00b2} + ... + k5*\u{03b8}\u{2076}, post_scale=(k6,k7)
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t3 = t2 * theta;
        float t4 = t2 * t2; float t5 = t4 * theta; float t6 = t3 * t3;
        float theta_d = distK[0].x*theta + distK[0].y*t2 + distK[0].z*t3
                       + distK[0].w*t4 + distK[1].x*t5 + distK[1].y*t6;
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        return pos * scale * post_scale;
    }
    return pos;
}

vec2 rotate_and_distort(vec2 out_px, float texY) {
    vec4 m0 = texture(matTex, vec2(0.125, texY));
    vec4 m1 = texture(matTex, vec2(0.375, texY));
    vec4 m2 = texture(matTex, vec2(0.625, texY));
    vec4 m3 = texture(matTex, vec2(0.875, texY));
    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return vec2(-99999.0);
    vec2 dp = distort_point(_x, _y, _w);
    if (dp.x < -99998.0) return dp;
    vec2 pt = fIn * dp;
    float sx = m0.a; float sy = m1.a; float ra = m2.a;
    float ox = m3.r; float oy = m3.g;
    if (sx != 0.0 || sy != 0.0 || ra != 0.0 || ox != 0.0 || oy != 0.0) {
        float cos_a = cos(-ra);
        float sin_a = sin(-ra);
        pt = vec2(cos_a * pt.x - sin_a * pt.y - sx + ox,
                  sin_a * pt.x + cos_a * pt.y - sy + oy);
    }
    return pt + cIn;
}
void main() {
    vec2 out_px = vec2(uv.x * videoSize.x, (1.0 - uv.y) * videoSize.y);
    // Lens correction: undistort output coords (matches gyroflow pipeline).
    // lensCorr = lens_correction_amount: 1.0 = no undistort, 0.0 = full undistort.
    // Auto-zoom in gyroflow-core compensates for this expansion.
    // NOTE: gyroflow uses frame center (videoSize/2) as undistort origin,
    // matching K_new which sets principal point = output center.
    if (distModel != 0 && frameFov > 0.0 && lensCorr < 1.0) {
        float factor = max(1.0 - lensCorr, 0.001);
        vec2 out_c = videoSize * 0.5;
        vec2 out_f = fIn / frameFov / factor;
        vec2 norm  = (out_px - out_c) / out_f;
        vec2 corr  = undistort_point(norm);
        vec2 undist = corr * out_f + out_c;
        out_px = undist * (1.0 - lensCorr) + out_px * lensCorr;
    }
    float sy = clamp(out_px.y, 0.0, matCount - 1.0);
    if (matCount > 1.0) {
        float midTexY = (floor(matCount * 0.5) + 0.5) / matCount;
        vec2 midPt = rotate_and_distort(out_px, midTexY);
        if (midPt.x > -99998.0) {
            sy = clamp(floor(0.5 + midPt.y), 0.0, matCount - 1.0);
        }
    }
    float texY = (sy + 0.5) / matCount;
    vec2 src_px = rotate_and_distort(out_px, texY);
    if (src_px.x < -99998.0) { fragColor = vec4(0.0,0.0,0.0,1.0); return; }
    vec2 src = vec2(src_px.x / videoSize.x, 1.0 - src_px.y / videoSize.y);
    // Clamp to frame edge instead of rendering black \u{2014} hides thin border artifacts.
    src = clamp(src, vec2(0.0), vec2(1.0));
    fragColor = texture(tex, src);
}
"""

    static let blitFragmentCore: String = """
#version 150
in vec2 uv;
out vec4 fragColor;
uniform sampler2D tex;
void main() {
    fragColor = texture(tex, uv);
}
"""

    // MARK: Legacy Profile (#version 120)

    static let vertexLegacy: String = """
#version 120
attribute vec2 pos;
varying vec2 uv;
void main() {
    uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);
}
"""

    static let fragmentLegacy: String = """
#version 120
varying vec2 uv;
uniform sampler2D tex;
uniform sampler2D matTex;
uniform vec2  videoSize;
uniform float matCount;
uniform vec2  fIn;
uniform vec2  cIn;
uniform vec4  distK[3];
uniform int   distModel;
uniform float rLimit;
uniform float frameFov;
uniform float lensCorr;

vec2 undistort_point(vec2 pos) {
    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta_d = clamp(length(pos), -1.5707963, 1.5707963);
        float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t4 = t2*t2; float t6 = t4*t2; float t8 = t6*t2;
                float k0t2 = distK[0].x*t2; float k1t4 = distK[0].y*t4;
                float k2t6 = distK[0].z*t6; float k3t8 = distK[0].w*t8;
                float theta_fix = (theta*(1.0+k0t2+k1t4+k2t6+k3t8) - theta_d)
                                / (1.0+3.0*k0t2+5.0*k1t4+7.0*k2t6+9.0*k3t8);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return pos * scale;
        return vec2(0.0);
    }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        vec2 p = pos / post_scale;
        float theta_d = length(p); float theta = theta_d; float scale = 0.0; bool converged = false;
        if (abs(theta_d) > 1e-6) {
            for (int i = 0; i < 10; i++) {
                float t2 = theta*theta; float t3 = t2*theta; float t4 = t2*t2; float t5 = t4*theta;
                float k0 = distK[0].x; float k1t = distK[0].y*theta; float k2t2 = distK[0].z*t2;
                float k3t3 = distK[0].w*t3; float k4t4 = distK[1].x*t4; float k5t5 = distK[1].y*t5;
                float theta_fix = (theta*(k0+k1t+k2t2+k3t3+k4t4+k5t5) - theta_d)
                                / (k0+2.0*k1t+3.0*k2t2+4.0*k3t3+5.0*k4t4+6.0*k5t5);
                theta -= theta_fix;
                if (abs(theta_fix) < 1e-6) { converged = true; break; }
            }
            scale = tan(theta) / theta_d;
        } else { converged = true; }
        bool flipped = (theta_d < 0.0 && theta > 0.0) || (theta_d > 0.0 && theta < 0.0);
        if (converged && !flipped) return p * scale;
        return vec2(0.0);
    }
    return pos;
}

vec2 distort_point(float x, float y, float w) {
    vec2 pos = vec2(x, y) / w;
    if (distModel == 0) return pos;
    float r = length(pos);
    if (rLimit > 0.0 && r > rLimit) return vec2(-99999.0);
    if (distModel == 1) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t4 = t2 * t2; float t6 = t4 * t2; float t8 = t4 * t4;
        float theta_d = theta * (1.0 + distK[0].x*t2 + distK[0].y*t4 + distK[0].z*t6 + distK[0].w*t8);
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        return pos * scale;
    }
    if (distModel == 3) {
        float poly2 = distK[0].x * (pos.x*pos.x + pos.y*pos.y) + 1.0;
        return pos * poly2;
    }
    if (distModel == 4) {
        float r2 = pos.x*pos.x + pos.y*pos.y;
        float poly4 = 1.0 + distK[0].x * r2 + distK[0].y * r2 * r2;
        return pos * poly4;
    }
    if (distModel == 7) {
        if (distK[0].x == 0.0 && distK[0].y == 0.0 && distK[0].z == 0.0 && distK[0].w == 0.0) return pos;
        float theta = atan(r);
        float t2 = theta * theta; float t3 = t2 * theta;
        float t4 = t2 * t2; float t5 = t4 * theta; float t6 = t3 * t3;
        float theta_d = distK[0].x*theta + distK[0].y*t2 + distK[0].z*t3
                       + distK[0].w*t4 + distK[1].x*t5 + distK[1].y*t6;
        float scale = (r == 0.0) ? 1.0 : theta_d / r;
        vec2 post_scale = distK[1].zw;
        if (post_scale.x == 0.0 && post_scale.y == 0.0) post_scale = vec2(1.0);
        return pos * scale * post_scale;
    }
    return pos;
}

vec2 rotate_and_distort(vec2 out_px, float texY) {
    vec4 m0 = texture2D(matTex, vec2(0.125, texY));
    vec4 m1 = texture2D(matTex, vec2(0.375, texY));
    vec4 m2 = texture2D(matTex, vec2(0.625, texY));
    vec4 m3 = texture2D(matTex, vec2(0.875, texY));
    float _x = m0.r*out_px.x + m0.g*out_px.y + m0.b;
    float _y = m1.r*out_px.x + m1.g*out_px.y + m1.b;
    float _w = m2.r*out_px.x + m2.g*out_px.y + m2.b;
    if (_w <= 0.0) return vec2(-99999.0);
    vec2 dp = distort_point(_x, _y, _w);
    if (dp.x < -99998.0) return dp;
    vec2 pt = fIn * dp;
    float sx = m0.a; float sy = m1.a; float ra = m2.a;
    float ox = m3.r; float oy = m3.g;
    if (sx != 0.0 || sy != 0.0 || ra != 0.0 || ox != 0.0 || oy != 0.0) {
        float cos_a = cos(-ra);
        float sin_a = sin(-ra);
        pt = vec2(cos_a * pt.x - sin_a * pt.y - sx + ox,
                  sin_a * pt.x + cos_a * pt.y - sy + oy);
    }
    return pt + cIn;
}
void main() {
    vec2 out_px = vec2(uv.x * videoSize.x, (1.0 - uv.y) * videoSize.y);
    if (distModel != 0 && frameFov > 0.0 && lensCorr < 1.0) {
        float factor = max(1.0 - lensCorr, 0.001);
        vec2 out_c = videoSize * 0.5;
        vec2 out_f = fIn / frameFov / factor;
        vec2 norm  = (out_px - out_c) / out_f;
        vec2 corr  = undistort_point(norm);
        vec2 undist = corr * out_f + out_c;
        out_px = undist * (1.0 - lensCorr) + out_px * lensCorr;
    }
    float sy = clamp(out_px.y, 0.0, matCount - 1.0);
    if (matCount > 1.0) {
        float midTexY = (floor(matCount * 0.5) + 0.5) / matCount;
        vec2 midPt = rotate_and_distort(out_px, midTexY);
        if (midPt.x > -99998.0) {
            sy = clamp(floor(0.5 + midPt.y), 0.0, matCount - 1.0);
        }
    }
    float texY = (sy + 0.5) / matCount;
    vec2 src_px = rotate_and_distort(out_px, texY);
    if (src_px.x < -99998.0) { gl_FragColor = vec4(0.0,0.0,0.0,1.0); return; }
    vec2 src = vec2(src_px.x / videoSize.x, 1.0 - src_px.y / videoSize.y);
    src = clamp(src, vec2(0.0), vec2(1.0));
    gl_FragColor = texture2D(tex, src);
}
"""

    static let blitFragmentLegacy: String = """
#version 120
varying vec2 uv;
uniform sampler2D tex;
void main() {
    gl_FragColor = texture2D(tex, uv);
}
"""

    // MARK: Shader Compilation

    static func compile(_ type: GLenum, _ source: String) -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { ptr in
            var p: UnsafePointer<GLchar>? = ptr
            glShaderSource(shader, 1, &p, nil)
        }
        glCompileShader(shader)
        var status = GLint(0)
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
        if status == GLint(GL_FALSE) {
            var log = [GLchar](repeating: 0, count: 512)
            glGetShaderInfoLog(shader, 512, nil, &log)
            print("[Warp] Shader compile error: \(String(cString: log))")
            glDeleteShader(shader); return 0
        }
        return shader
    }
}
