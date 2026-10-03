package dev.captience.beamcraft.client.mixin;

import com.mojang.blaze3d.audio.Listener;
import com.mojang.blaze3d.audio.ListenerTransform;
import dev.captience.beamcraft.client.BeamCraftClient;
import net.minecraft.client.Camera;
import net.minecraft.client.sounds.SoundEngine;
import net.minecraft.client.sounds.SoundEngineExecutor;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Minecraft hears from BeamNG's camera while you drive or fly around: otherwise every
 * sound was mixed as if you still stood where Steve was left.
 */
@Mixin(SoundEngine.class)
public abstract class SoundEngineMixin {
	@Shadow private boolean loaded;
	@Shadow @Final private Listener listener;
	@Shadow @Final private SoundEngineExecutor executor;

	@Inject(method = "updateSource", at = @At("HEAD"), cancellable = true)
	private void beamcraft$listenAtBeamNGCamera(Camera camera, CallbackInfo ci) {
		ListenerTransform t = BeamCraftClient.beamngListener();
		if (t == null) return;
		ci.cancel();
		if (loaded) executor.execute(() -> listener.setTransform(t));
	}
}
