#language slang 2026
import kitty_custom_shader_types;

float noise(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

public float4 fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 size = max(float2(d.viewport_size_pixels), float2(1.0));
    float2 pointer = d.mouse_pos.xy;
    bool visible = d.mouse_pointer_hidden == 0.0 && all(pointer >= float2(0.0)) && all(pointer <= float2(1.0));
    float4 previous = t.persist.Sample(float2(0.5) / size);
    bool initialized = previous.w > 0.74 && previous.w < 0.76;
    float2 pixel = t.pos * size;
    if (all(pixel < float2(1.0)))
        return float4(clamp(pointer, float2(0.0), float2(1.0)), visible ? 1.0 : 0.0, 0.75);

    float dt = clamp(d.timestamp - d.last_rendered_at, 0.001, 2.0);
    float3 trail = initialized ? t.persist.Sample(t.pos).rgb * exp(-8.0 * dt) : float3(0.0);
    if (max(trail.r, max(trail.g, trail.b)) < 0.004) trail = float3(0.0);
    float2 move = (pointer - previous.xy) * size;
    float distanceSquared = dot(move, move);
    if (visible && initialized && previous.z > 0.5 && distanceSquared > 0.5 && distanceSquared < 62500.0) {
        float2 grid = floor(pixel / 12.0);
        float seed = noise(grid);
        float2 center = (grid + float2(0.5)) * 12.0;
        center += float2(noise(grid + 2.0), noise(grid + 9.0)) * 7.0 - 3.5;
        float along = saturate(dot(center - previous.xy * size, move) / max(distanceSquared, 0.01));
        float distanceToPath = length(center - (previous.xy * size + move * along));
        float dotShape = exp(-dot(pixel - center, pixel - center) / 7.0);
        float emit = (seed > 0.50 ? 1.0 : 0.0) * (1.0 - smoothstep(10.0, 28.0, distanceToPath)) * dotShape;
        float3 tint = lerp(float3(0.08, 0.32, 0.55), float3(0.28, 0.13, 0.5), seed);
        trail = max(trail, tint * emit);
    }
    return float4(saturate(trail), 1.0);
}
