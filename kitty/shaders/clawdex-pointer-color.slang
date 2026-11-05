#language slang 2026
import kitty_custom_shader_types;
public float4 fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 pointer = d.mouse_pos.xy;
    if (d.mouse_pointer_hidden != 0.0 || any(pointer < float2(0.0)) || any(pointer > float2(1.0)))
        return color;
    float2 delta = (t.pos - pointer) * float2(d.viewport_size_pixels);
    float falloff = 1.0 - smoothstep(5.0, 110.0, length(delta));
    float opacity = 0.12 * falloff * falloff;
    float phase = 0.5 + 0.5 * sin(d.timestamp * 0.7 + length(delta) * 0.016);
    float3 amber = float3(0.65, 0.24, 0.035);
    float3 peach = float3(0.75, 0.30, 0.18);
    float3 rose = float3(0.60, 0.09, 0.23);
    float3 tint = phase < 0.5 ? lerp(amber, peach, phase * 2.0)
                              : lerp(peach, rose, phase * 2.0 - 1.0);
    return float4(lerp(color.rgb, tint, opacity), color.a);
}
