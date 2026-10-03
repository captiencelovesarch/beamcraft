package dev.captience.beamcraft.client.mixin;

import net.minecraft.client.model.EntityModel;
import net.minecraft.client.renderer.entity.AgeableMobRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Ageable renderers only swap in the baby model while drawing; we never draw. */
@Mixin(AgeableMobRenderer.class)
public interface AgeableMobRendererAccess {
	@Accessor("adultModel") EntityModel<?> beamcraft$adult();
	@Accessor("babyModel") EntityModel<?> beamcraft$baby();
}
