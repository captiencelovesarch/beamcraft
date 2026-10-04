package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.BeamCraftClient;
import net.minecraft.client.renderer.rendertype.TextureTransform;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/**
 * The enchantment glint scrolls with the wall clock, so an enchanted item in first
 * person changes ~40 overlay tiles on every frame BeamNG pulls, and each frame's
 * tiles have to be loaded as a texture there. Stepping the glint's clock at 20 Hz
 * looks the same (it moves a fraction of a percent of its texture per step) and leaves
 * the frames in between with only what really moved.
 */
@Mixin(TextureTransform.class)
abstract class GlintClockMixin {
	private static final long STEP_MS = 50;

	@Redirect(method = "setupGlintTexturing", at = @At(value = "INVOKE", target = "Lnet/minecraft/util/Util;getMillis()J"))
	private static long beamcraft$steppedClock() {
		long ms = net.minecraft.util.Util.getMillis();
		return BeamCraftClient.HEADLESS ? ms - ms % STEP_MS : ms;
	}
}
