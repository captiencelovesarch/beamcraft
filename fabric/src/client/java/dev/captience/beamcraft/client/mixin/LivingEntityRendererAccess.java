package dev.captience.beamcraft.client.mixin;

import com.mojang.blaze3d.vertex.PoseStack;
import net.minecraft.client.model.EntityModel;
import net.minecraft.client.renderer.entity.LivingEntityRenderer;
import net.minecraft.client.renderer.entity.state.LivingEntityRenderState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
import org.spongepowered.asm.mixin.gen.Invoker;

/** The renderer's own body transforms, so BeamNG poses entities exactly like vanilla. */
@Mixin(LivingEntityRenderer.class)
public interface LivingEntityRendererAccess {
	@Invoker("setupRotations") void beamcraft$setupRotations(LivingEntityRenderState state, PoseStack poseStack, float bodyRot, float entityScale);
	@Invoker("scale") void beamcraft$scale(LivingEntityRenderState state, PoseStack poseStack);
	@Accessor("model") EntityModel<?> beamcraft$model();
}
