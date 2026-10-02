package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.BeamCraftClient;
import com.mojang.blaze3d.platform.FramerateLimitTracker;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * The hidden client never "goes AFK" (BeamNG input doesn't count as window input) and
 * isn't capped: its overlay should refresh as fast as BeamNG draws.
 */
@Mixin(FramerateLimitTracker.class)
public abstract class FramerateLimitTrackerMixin {
	@Inject(method = "getFramerateLimit", at = @At("HEAD"), cancellable = true)
	private void beamcraft$steadyFps(CallbackInfoReturnable<Integer> cir) {
		if (BeamCraftClient.HEADLESS) cir.setReturnValue(BeamCraftClient.targetFps());
	}
}
