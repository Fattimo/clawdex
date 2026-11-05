#language slang 2026
import kitty_custom_shader_types;
public float4 fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 size = max(float2(d.viewport_size_pixels), float2(1.0));
    if (all(t.pos * size < float2(1.0))) return color;
    float3 trail = t.persist.Sample(t.pos).rgb;
    float strength = max(trail.r, max(trail.g, trail.b));
    float opacity = min(0.7, strength * 1.4);
    float3 tint = lerp(trail / max(strength, 0.001), float3(1.0), 0.3);
    return float4(lerp(color.rgb, saturate(tint), opacity), color.a);
}
