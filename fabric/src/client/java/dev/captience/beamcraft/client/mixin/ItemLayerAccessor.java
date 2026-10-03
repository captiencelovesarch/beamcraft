package dev.captience.beamcraft.client.mixin;
import net.minecraft.client.renderer.item.ItemStackRenderState;
import com.mojang.blaze3d.vertex.PoseStack;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;
@Mixin(ItemStackRenderState.LayerRenderState.class)
public interface ItemLayerAccessor {
 @Invoker("submit") void beamcraft$submit(PoseStack pose, net.minecraft.client.renderer.SubmitNodeCollector collector, int light, int overlay, int outline);
 @Invoker("applyTransform") void beamcraft$transform(PoseStack.Pose pose);
}
