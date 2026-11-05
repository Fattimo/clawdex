#language slang 2026
import kitty_custom_shader_types;
public float4 fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 delta = abs((t.pos - d.mouse_pos.zw) * float2(d.viewport_size_pixels));
    float core = exp(-dot(delta, delta) / 12.0);
    float cross = exp(-delta.x * delta.x / 1.5 - delta.y * delta.y / 110.0)
                + exp(-delta.y * delta.y / 1.5 - delta.x * delta.x / 110.0);
    float fade = 1.0 - saturate(t.animation_progress);
    float sparkle = (core + cross * 0.55) * fade;
    return float4(saturate(color.rgb + float3(0.15, 0.3, 0.55) * sparkle), color.a);
}
