#language slang 2026
import kitty_custom_shader_types;
public float4 fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    return t.a.Sample(t.pos);
}
