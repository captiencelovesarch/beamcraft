package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.BeamCraftClient;
import dev.captience.beamcraft.client.TerrainAim;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(Minecraft.class)
public abstract class MinecraftPickMixin {
	/** After vanilla picks, let the crosshair land on BeamNG ground so blocks can be placed on it. */
	@Inject(method = "pick", at = @At("TAIL"))
	private void beamcraft$aimAtTerrain(float partialTicks, CallbackInfo ci) {
		TerrainAim.apply((Minecraft) (Object) this);
	}

	/** The hidden window never has OS focus; BeamNG's input is its focus. */
	@Inject(method = "isWindowActive", at = @At("HEAD"), cancellable = true)
	private void beamcraft$alwaysActive(CallbackInfoReturnable<Boolean> cir) {
		if (BeamCraftClient.HEADLESS) cir.setReturnValue(true);
	}
}
