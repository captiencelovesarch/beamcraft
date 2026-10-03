package dev.captience.beamcraft.client.mixin;
import net.minecraft.client.particle.SingleQuadParticle;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.*;
@Mixin(SingleQuadParticle.class)
public interface QuadParticleAccessor {
 @Accessor("sprite") TextureAtlasSprite beamcraft$sprite();
 @Accessor("rCol") float beamcraft$r();
 @Accessor("gCol") float beamcraft$g();
 @Accessor("bCol") float beamcraft$b();
 @Accessor("alpha") float beamcraft$alpha();
 @Accessor("roll") float beamcraft$roll();
 @Invoker("getU0") float beamcraft$u0();
 @Invoker("getU1") float beamcraft$u1();
 @Invoker("getV0") float beamcraft$v0();
 @Invoker("getV1") float beamcraft$v1();
}
