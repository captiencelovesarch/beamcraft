package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.BeamCraftClient;
import net.minecraft.client.Minecraft;
import net.minecraft.client.MouseHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/** Holding attack keeps mining only while the mouse is "grabbed"; BeamNG has it grabbed unless a screen is open. */
@Mixin(MouseHandler.class)
public abstract class MouseHandlerMixin {
	@Inject(method = "isMouseGrabbed", at = @At("HEAD"), cancellable = true)
	private void beamcraft$grabbedWhileControlled(CallbackInfoReturnable<Boolean> cir) {
		if (BeamCraftClient.isControlling()) cir.setReturnValue(Minecraft.getInstance().gui.screen() == null);
	}
}
