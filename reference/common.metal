#include <metal_stdlib>
using namespace metal;

#define PI 3.1415926535897932384626433832795
#define TAU (2.0 * PI)

struct Uniforms {
    float3 iResolution;
    float iTime;
    float iTimeDelta;
    float splitMode;
    float2 iMouse;
};

struct VertexOut {
    float4 pos [[position]];
    float2 uv;
};

constant float2 quadPositions[4] = {
    float2(-1,  1),
    float2(-1, -1),
    float2( 1,  1),
    float2( 1, -1),
};
constant float2 quadUVs[4] = {
    float2(0, 1),
    float2(0, 0),
    float2(1, 1),
    float2(1, 0),
};

vertex VertexOut vertexShader(uint vid [[vertex_id]]) {
    VertexOut out;
    out.pos = float4(quadPositions[vid], 0, 1);
    out.uv = quadUVs[vid];
    return out;
}

// Sample the screen capture at a UV coordinate (bottom-left origin).
// Handles the Y flip between UV space and texture space internally.
float4 screen(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, float2(uv.x, 1.0 - uv.y));
}

fragment float4 passthroughFragment(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    sampler s [[sampler(0)]],
                                    constant Uniforms& u [[buffer(0)]]) {
    if (u.splitMode > 0.5 && in.uv.x < 0.5) discard_fragment();
    return screen(tex, s, in.uv);
}

// --- Math ---

float one_minus(float a) { return 1.0 - a; }

float floor_to_nearest(float value, float step) {
    return floor(value / step) * step;
}

float2 floor_to_nearest2(float2 value, float2 step) {
    return floor(value / step) * step;
}

float map_range(float value, float min1, float max1, float min2, float max2) {
    return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
}

float map01(float value, float bottom, float top) {
    return map_range(value, 0.0, 1.0, bottom, top);
}

// --- Polar ---

float2 cartesian_to_polar_long_lat(float3 xyz) {
    float r = length(xyz);
    float long_ = atan2(xyz.y, xyz.x);
    float lat = acos(xyz.z / r);
    return float2(long_, lat);
}

float2 xy_to_r_theta(float2 xy) {
    return float2(length(xy), atan2(xy.y, xy.x));
}

float2 r_theta_to_xy(float2 rt) {
    return float2(rt.x * cos(rt.y), rt.x * sin(rt.y));
}

float2 back_to_front_bottom_to_top(float3 unit_ray) {
    float2 uv = cartesian_to_polar_long_lat(unit_ray);
    uv.y /= PI;
    uv.y = one_minus(uv.y);
    float2 uv2 = cartesian_to_polar_long_lat(unit_ray.xzy);
    uv2.y = one_minus(uv2.y / PI);
    return float2(uv.y, uv2.y);
}

// --- Color ---

constant float3 rainbow_colors[7] = {
    float3(1.0, 0.0, 0.0),
    float3(1.0, 0.5, 0.0),
    float3(1.0, 1.0, 0.0),
    float3(0.0, 1.0, 0.0),
    float3(0.0, 0.0, 1.0),
    float3(0.29, 0.0, 0.51),
    float3(0.93, 0.51, 0.93),
};

float3 rainbow_gradient(float value) {
    value = clamp(value, 0.0, 1.0);
    float segment = 1.0 / 6.0;
    float segment_index = floor(value / segment);
    float segment_value = fract(value / segment);
    float3 color1 = rainbow_colors[int(segment_index)];
    float3 color2 = rainbow_colors[int(segment_index + 1.0)];
    return mix(color1, color2, segment_value);
}

float3 palette(float3 a, float3 b, float3 c, float3 d, float t) {
    return a + b * cos(6.28318 * (c * t + d));
}

float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float3 replace_rgb(float3 old_color, float3 new_r, float3 new_g, float3 new_b) {
    return new_r * old_color.x + new_g * old_color.y + new_b * old_color.z;
}

// --- Waves ---

float sin01(float value) { return (sin(value) + 1.0) * 0.5; }

float sin01ma(float t, float period_secs, float offset_secs, float m, float a) {
    return sin01((t + offset_secs) / period_secs * 2.0 * PI) * m + a;
}

float stay01(float t, float period_secs, float offset_secs, float power) {
    float wave = sin((t + offset_secs) / period_secs * 2.0 * PI);
    float s = sign(wave);
    return map_range(s - (s * pow(1.0 - abs(wave), power)), -1.0, 1.0, 0.0, 1.0);
}

float stay(float t, float start, float stop, float period_secs, float offset_secs, float power) {
    return stay01(t, period_secs, offset_secs, power) * (stop - start) + start;
}

float triangle_wave(float t) { return 2.0 * abs(fract(t + 0.5) - 0.5); }

float square_wave(float t) { return float(0.5 < fract(t)); }

// --- UV helpers ---

float2 with_u(float2 uv, float new_value) { return float2(new_value, uv.y); }
float2 with_v(float2 uv, float new_value) { return float2(uv.x, new_value); }

float2 rotate2d(float2 v, float radians) {
    float s = sin(radians);
    float c = cos(radians);
    return float2x2(float2(c, s), float2(-s, c)) * v;
}

// --- SDF ---

float rect_sdf(float2 uv, float2 center, float2 size) {
    float2 d = abs(uv - center) - size;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float circle_sdf(float2 uv, float2 center, float size) {
    return length(uv - center) - size;
}

float sphere_sdf(float3 p, float size) { return length(p) - size; }

float box_sdf(float3 p, float3 size) {
    float3 q = abs(p) - size;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float menger_sponge_sdf(float3 p, int iterations) {
    float box = box_sdf(p, float3(1.0));
    float d = box;
    float s = 2.67;
    for (int i = 0; i < iterations; i++) {
        float3 a = fmod(p * s, 2.0) - 1.0;
        s *= 3.0;
        float3 r = abs(1.0 - 3.0 * abs(a));
        float da = max(r.x, r.y);
        float db = max(r.y, r.z);
        float dc = max(r.z, r.x);
        float c = (min(da, min(db, dc)) - 1.0) / s;
        d = max(d, c);
    }
    return max(d, box_sdf(p - 0.5, float3(0.50)));
}

float smin(float a, float b, float k) {
    float res = exp2(-k * a) + exp2(-k * b);
    return -log2(res) / k;
}

// --- Noise: hash / white noise ---
// hash_1d: any dimension in → float out
float hash_1d(float x) { return fract(sin(x * 12.9898) * 43758.5453); }
float hash_1d(float2 x) { return fract(sin(dot(x, float2(12.9898, 78.233))) * 43758.5453123); }
float hash_1d(float3 x) { return fract(sin(dot(x, float3(12.9898, 78.233, 45.164))) * 43758.5453); }

// hash_2d: any dimension in → float2 out
float2 hash_2d(float x) { return float2(hash_1d(x), hash_1d(x + 17.0)); }
float2 hash_2d(float2 x) { return float2(hash_1d(x), hash_1d(x + 17.0)); }
float2 hash_2d(float3 x) { return float2(hash_1d(x), hash_1d(x + 17.0)); }

// hash_3d: any dimension in → float3 out
float3 hash_3d(float x) { return float3(hash_1d(x), hash_1d(x + 17.0), hash_1d(x + 31.0)); }
float3 hash_3d(float2 x) { return float3(hash_1d(x), hash_1d(x + 17.0), hash_1d(x + 31.0)); }
float3 hash_3d(float3 x) { return float3(hash_1d(x), hash_1d(x + 17.0), hash_1d(x + 31.0)); }

// Legacy aliases
float random_f(float2 uv) { return hash_1d(uv); }
float white_noise_1d(float x) { return hash_1d(x); }
float2 white_noise_2d(float2 x) { return fract(sin(x * float2(12.9898, 78.233)) * 43758.5453); }
float3 white_noise_3d(float3 x) { return fract(sin(x * float3(12.9898, 78.233, 45.164)) * 43758.5453); }

// --- Noise: simple (value noise) ---

float simple_noise_value(float x) {
    float i = floor(x);
    float f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash_1d(i), hash_1d(i + 1.0), f);
}

float simple_noise_value(float2 uv) {
    float2 i = floor(uv);
    float2 f = fract(uv);
    f = f * f * (3.0 - 2.0 * f);
    float r0 = hash_1d(i + float2(0.0, 0.0));
    float r1 = hash_1d(i + float2(1.0, 0.0));
    float r2 = hash_1d(i + float2(0.0, 1.0));
    float r3 = hash_1d(i + float2(1.0, 1.0));
    return mix(mix(r0, r1, f.x), mix(r2, r3, f.x), f.y);
}

float simple_noise_value(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash_1d(i + float3(0, 0, 0));
    float n100 = hash_1d(i + float3(1, 0, 0));
    float n010 = hash_1d(i + float3(0, 1, 0));
    float n110 = hash_1d(i + float3(1, 1, 0));
    float n001 = hash_1d(i + float3(0, 0, 1));
    float n101 = hash_1d(i + float3(1, 0, 1));
    float n011 = hash_1d(i + float3(0, 1, 1));
    float n111 = hash_1d(i + float3(1, 1, 1));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

float simple_noise(float x) {
    float t = 0.0;
    for (int i = 0; i < 3; i++) {
        float freq = pow(2.0, float(i));
        float amp = pow(0.5, float(3 - i));
        t += simple_noise_value(x / freq) * amp;
    }
    return t;
}

float simple_noise(float2 uv) {
    float t = 0.0;
    for (int i = 0; i < 3; i++) {
        float freq = pow(2.0, float(i));
        float amp = pow(0.5, float(3 - i));
        t += simple_noise_value(uv / freq) * amp;
    }
    return t;
}

float simple_noise(float3 p) {
    float t = 0.0;
    for (int i = 0; i < 3; i++) {
        float freq = pow(2.0, float(i));
        float amp = pow(0.5, float(3 - i));
        t += simple_noise_value(p / freq) * amp;
    }
    return t;
}

// simple_noise_2d / simple_noise_3d: vector-output variants
float2 simple_noise_2d(float x) { return float2(simple_noise(x), simple_noise(x + 17.0)); }
float2 simple_noise_2d(float2 x) { return float2(simple_noise(x), simple_noise(x + 17.0)); }
float2 simple_noise_2d(float3 x) { return float2(simple_noise(x), simple_noise(x + 17.0)); }
float3 simple_noise_3d(float x) { return float3(simple_noise(x), simple_noise(x + 17.0), simple_noise(x + 31.0)); }
float3 simple_noise_3d(float2 x) { return float3(simple_noise(x), simple_noise(x + 17.0), simple_noise(x + 31.0)); }
float3 simple_noise_3d(float3 x) { return float3(simple_noise(x), simple_noise(x + 17.0), simple_noise(x + 31.0)); }

// --- Noise: voronoi ---

float voronoi_noise(float2 uv) {
    float2 indexUV = floor(uv);
    float2 fractUV = fract(uv);
    float minDist = 1.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 neighbor = float2(float(x), float(y));
            float rand = hash_1d(indexUV + neighbor);
            float2 point = float2(rand, rand);
            float2 diff = neighbor + point - fractUV;
            minDist = min(minDist, length(diff));
        }
    }
    return minDist;
}

// --- Noise: perlin ---
// Adapted from webgl-noise (Ashima Arts / Stefan Gustavson), MIT licence.
// https://github.com/ashima/webgl-noise  -  see LICENSE for the full notice.

float4 perlin_noise_permute(float4 x) {
    return fmod((34.0 * x + 1.0) * x, 289.0);
}

float perlin_noise_permute1(float x) {
    return fmod((34.0 * x + 1.0) * x, 289.0);
}

float2 perlin_noise_fade(float2 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float3 perlin_noise_fade3(float3 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float perlin_noise(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float g0 = 2.0 * hash_1d(i) - 1.0;
    float g1 = 2.0 * hash_1d(i + 1.0) - 1.0;
    float n = mix(g0 * f, g1 * (f - 1.0), u);
    return n * 0.5 + 0.5;
}

float perlin_noise(float2 P) {
    float4 Pi = floor(P.xyxy) + float4(0.0, 0.0, 1.0, 1.0);
    float4 Pf = fract(P.xyxy) - float4(0.0, 0.0, 1.0, 1.0);
    Pi = fmod(Pi, 289.0);
    float4 ix = Pi.xzxz;
    float4 iy = Pi.yyww;
    float4 fx = Pf.xzxz;
    float4 fy = Pf.yyww;
    float4 i = perlin_noise_permute(perlin_noise_permute(ix) + iy);
    float4 gx = 2.0 * fract(i * 0.0243902) - 1.0;
    float4 gy = abs(gx) - 0.5;
    float4 tx = floor(gx + 0.5);
    gx = gx - tx;
    float2 g00 = float2(gx.x, gy.x);
    float2 g10 = float2(gx.y, gy.y);
    float2 g01 = float2(gx.z, gy.z);
    float2 g11 = float2(gx.w, gy.w);
    float4 norm = 1.79284291400159 - 0.85373472095314 * float4(dot(g00, g00), dot(g01, g01), dot(g10, g10), dot(g11, g11));
    g00 *= norm.x; g01 *= norm.y; g10 *= norm.z; g11 *= norm.w;
    float n00 = dot(g00, float2(fx.x, fy.x));
    float n10 = dot(g10, float2(fx.y, fy.y));
    float n01 = dot(g01, float2(fx.z, fy.z));
    float n11 = dot(g11, float2(fx.w, fy.w));
    float2 fade_xy = perlin_noise_fade(Pf.xy);
    float2 n_x = mix(float2(n00, n01), float2(n10, n11), fade_xy.x);
    float n_xy = mix(n_x.x, n_x.y, fade_xy.y);
    return 2.3 * n_xy * 0.5 + 0.5;
}

float perlin_noise(float3 P) {
    float3 Pi0 = floor(P);
    float3 Pi1 = Pi0 + 1.0;
    Pi0 = fmod(Pi0, 289.0);
    Pi1 = fmod(Pi1, 289.0);
    float3 Pf0 = fract(P);
    float3 Pf1 = Pf0 - 1.0;
    float4 ix = float4(Pi0.x, Pi1.x, Pi0.x, Pi1.x);
    float4 iy = float4(Pi0.yy, Pi1.yy);
    float4 iz0 = float4(Pi0.z);
    float4 iz1 = float4(Pi1.z);
    float4 ixy = perlin_noise_permute(perlin_noise_permute(ix) + iy);
    float4 ixy0 = perlin_noise_permute(ixy + iz0);
    float4 ixy1 = perlin_noise_permute(ixy + iz1);
    float4 gx0 = ixy0 / 7.0;
    float4 gy0 = fract(floor(gx0) / 7.0) - 0.5;
    gx0 = fract(gx0);
    float4 gz0 = float4(0.5) - abs(gx0) - abs(gy0);
    float4 sz0 = step(gz0, float4(0.0));
    gx0 -= sz0 * (step(float4(0.0), gx0) - 0.5);
    gy0 -= sz0 * (step(float4(0.0), gy0) - 0.5);
    float4 gx1 = ixy1 / 7.0;
    float4 gy1 = fract(floor(gx1) / 7.0) - 0.5;
    gx1 = fract(gx1);
    float4 gz1 = float4(0.5) - abs(gx1) - abs(gy1);
    float4 sz1 = step(gz1, float4(0.0));
    gx1 -= sz1 * (step(float4(0.0), gx1) - 0.5);
    gy1 -= sz1 * (step(float4(0.0), gy1) - 0.5);
    float3 g000 = float3(gx0.x, gy0.x, gz0.x);
    float3 g100 = float3(gx0.y, gy0.y, gz0.y);
    float3 g010 = float3(gx0.z, gy0.z, gz0.z);
    float3 g110 = float3(gx0.w, gy0.w, gz0.w);
    float3 g001 = float3(gx1.x, gy1.x, gz1.x);
    float3 g101 = float3(gx1.y, gy1.y, gz1.y);
    float3 g011 = float3(gx1.z, gy1.z, gz1.z);
    float3 g111 = float3(gx1.w, gy1.w, gz1.w);
    float4 norm0 = 1.79284291400159 - 0.85373472095314 *
        float4(dot(g000, g000), dot(g010, g010), dot(g100, g100), dot(g110, g110));
    g000 *= norm0.x; g010 *= norm0.y; g100 *= norm0.z; g110 *= norm0.w;
    float4 norm1 = 1.79284291400159 - 0.85373472095314 *
        float4(dot(g001, g001), dot(g011, g011), dot(g101, g101), dot(g111, g111));
    g001 *= norm1.x; g011 *= norm1.y; g101 *= norm1.z; g111 *= norm1.w;
    float n000 = dot(g000, Pf0);
    float n100 = dot(g100, float3(Pf1.x, Pf0.yz));
    float n010 = dot(g010, float3(Pf0.x, Pf1.y, Pf0.z));
    float n110 = dot(g110, float3(Pf1.xy, Pf0.z));
    float n001 = dot(g001, float3(Pf0.xy, Pf1.z));
    float n101 = dot(g101, float3(Pf1.x, Pf0.y, Pf1.z));
    float n011 = dot(g011, float3(Pf0.x, Pf1.yz));
    float n111 = dot(g111, Pf1);
    float3 fade_xyz = perlin_noise_fade3(Pf0);
    float4 n_z = mix(float4(n000, n100, n010, n110), float4(n001, n101, n011, n111), fade_xyz.z);
    float2 n_yz = mix(n_z.xy, n_z.zw, fade_xyz.y);
    float n_xyz = mix(n_yz.x, n_yz.y, fade_xyz.x);
    return 2.2 * n_xyz * 0.5 + 0.5;
}

// perlin_noise_2d / perlin_noise_3d: vector-output variants
float2 perlin_noise_2d(float x) { return float2(perlin_noise(x), perlin_noise(x + 17.0)); }
float2 perlin_noise_2d(float2 x) { return float2(perlin_noise(x), perlin_noise(x + 17.0)); }
float2 perlin_noise_2d(float3 x) { return float2(perlin_noise(x), perlin_noise(x + 17.0)); }
float3 perlin_noise_3d(float x) { return float3(perlin_noise(x), perlin_noise(x + 17.0), perlin_noise(x + 31.0)); }
float3 perlin_noise_3d(float2 x) { return float3(perlin_noise(x), perlin_noise(x + 17.0), perlin_noise(x + 31.0)); }
float3 perlin_noise_3d(float3 x) { return float3(perlin_noise(x), perlin_noise(x + 17.0), perlin_noise(x + 31.0)); }

// --- Noise: turbulence (FBM) ---

float turbulence_noise(float x, float octaves) {
    float result = 0.0;
    float frequency = 1.0;
    float amplitude = 0.5;
    int octaves_i = int(octaves);
    for (int i = 0; i < octaves_i; i++) {
        result += perlin_noise(x * frequency) * amplitude;
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return result;
}

float turbulence_noise(float2 uv, float octaves) {
    float result = 0.0;
    float frequency = 1.0;
    float amplitude = 0.5;
    int octaves_i = int(octaves);
    for (int i = 0; i < octaves_i; i++) {
        result += perlin_noise(uv * frequency) * amplitude;
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return result;
}

float turbulence_noise(float3 p, float octaves) {
    float result = 0.0;
    float frequency = 1.0;
    float amplitude = 0.5;
    int octaves_i = int(octaves);
    for (int i = 0; i < octaves_i; i++) {
        result += perlin_noise(p * frequency) * amplitude;
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return result;
}

// turbulence_noise_2d / turbulence_noise_3d: vector-output variants
float2 turbulence_noise_2d(float x, float o) { return float2(turbulence_noise(x, o), turbulence_noise(x + 17.0, o)); }
float2 turbulence_noise_2d(float2 x, float o) { return float2(turbulence_noise(x, o), turbulence_noise(x + 17.0, o)); }
float2 turbulence_noise_2d(float3 x, float o) { return float2(turbulence_noise(x, o), turbulence_noise(x + 17.0, o)); }
float3 turbulence_noise_3d(float x, float o) { return float3(turbulence_noise(x, o), turbulence_noise(x + 17.0, o), turbulence_noise(x + 31.0, o)); }
float3 turbulence_noise_3d(float2 x, float o) { return float3(turbulence_noise(x, o), turbulence_noise(x + 17.0, o), turbulence_noise(x + 31.0, o)); }
float3 turbulence_noise_3d(float3 x, float o) { return float3(turbulence_noise(x, o), turbulence_noise(x + 17.0, o), turbulence_noise(x + 31.0, o)); }
