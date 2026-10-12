fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler s [[sampler(0)]],
                               constant Uniforms& u [[buffer(0)]]) {
    if (u.splitMode > 0.5 && in.uv.x > 0.5) discard_fragment();

    float2 uv = in.uv;
    float t = u.iTime;

    uv += -0.10;
    uv += random_f(float2(floor_to_nearest2(uv, float2(0.01)) + t)) * 0.005;

    float3 color = float3(
        screen(tex, s, fract(uv + 0.002 + (random_f(float2(floor_to_nearest(t, 0.3) * 0.189)) + sin(uv.y + t) * 0.003) * 0.02)).r,
        screen(tex, s, fract(uv - 0.002 - (random_f(float2(floor_to_nearest(t, 0.3) * 0.287)) + sin(uv.y + t) * 0.003) * 0.02)).g,
        screen(tex, s, fract(uv)).b
    );

    color = rgb2hsv(color);
    color.r = fract(color.b + random_f(float2(floor_to_nearest(color.g, 0.05))));
    color = hsv2rgb(color);

    return float4(color, 1.0);
}

