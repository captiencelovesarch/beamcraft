package dev.captience.beamcraft.client.mixin;
import net.minecraft.client.renderer.item.ItemStackRenderState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
@Mixin(ItemStackRenderState.class)
public interface ItemStateAccessor {
 @Accessor("layers") ItemStackRenderState.LayerRenderState[] beamcraft$layers();
 @Accessor("activeLayerCount") int beamcraft$count();
}
