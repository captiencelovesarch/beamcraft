package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.TerrainAim;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** After vanilla picks, let the crosshair land on BeamNG ground so blocks can be placed on it. */
@Mixin(Minecraft.class)
public abstract class MinecraftPickMixin {
	@Inject(method = "pick", at = @At("TAIL"))
	private void beamcraft$aimAtTerrain(float partialTicks, CallbackInfo ci) {
		TerrainAim.apply((Minecraft) (Object) this);
	}
}
