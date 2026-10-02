package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.BeamCraftClient;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.renderer.GameRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** BeamNG draws the world; the hidden client skips its own (software-rendered) world pass. */
@Mixin(GameRenderer.class)
public abstract class GameRendererMixin {
	@Inject(method = "renderLevel", at = @At("HEAD"), cancellable = true)
	private void beamcraft$skipWorld(DeltaTracker deltaTracker, CallbackInfo ci) {
		if (BeamCraftClient.HEADLESS) ci.cancel();
	}
}
