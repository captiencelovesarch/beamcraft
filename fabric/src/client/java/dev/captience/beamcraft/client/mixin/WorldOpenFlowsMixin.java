package dev.captience.beamcraft.client.mixin;

import net.minecraft.client.gui.screens.worldselection.WorldOpenFlows;
import net.minecraft.world.level.storage.LevelStorageSource;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * BeamCraft worlds use a custom (tall, void) dimension type, which vanilla flags as
 * "experimental" and answers with a backup prompt on every load. Nobody can click it
 * on a hidden client, so skip it for our own worlds.
 */
@Mixin(WorldOpenFlows.class)
public abstract class WorldOpenFlowsMixin {
	@Inject(method = "askForBackup", at = @At("HEAD"), cancellable = true)
	private void beamcraft$noBackupPrompt(LevelStorageSource.LevelStorageAccess levelAccess, boolean oldCustomized,
		Runnable proceedCallback, Runnable cancelCallback, CallbackInfo ci) {
		if (levelAccess.getLevelId().startsWith("beamcraft_")) {
			ci.cancel();
			proceedCallback.run();
		}
	}
}
