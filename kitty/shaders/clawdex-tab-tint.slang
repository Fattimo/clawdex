#language slang 2026
import kitty_custom_shader_types;

public float4 fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 position = t.pos - d.central_area.xy;
    if (any(position < float2(0.0)) || any(position > d.central_area.zw)) return color;
    float fade = 1.0 - saturate(t.animation_progress);
    float brightness = max(color.r, max(color.g, color.b));
    float backgroundWeight = 1.0 - smoothstep(0.03, 0.35, brightness);
    return float4(saturate(color.rgb + float3(0.002, 0.004, 0.008) * fade * backgroundWeight), color.a);
}
