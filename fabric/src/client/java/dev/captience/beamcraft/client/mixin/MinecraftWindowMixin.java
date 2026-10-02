package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.BeamCraftClient;
import net.minecraft.client.Minecraft;
import org.lwjgl.glfw.GLFW;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/**
 * The hidden client runs on the real display so it renders on the GPU, but its window
 * is never shown: vanilla creates it invisible and shows it once at startup; we skip
 * that. Everything it draws goes to an offscreen target that BeamNG overlays anyway.
 */
@Mixin(Minecraft.class)
public abstract class MinecraftWindowMixin {
	@Redirect(method = "<init>", at = @At(value = "INVOKE", target = "Lorg/lwjgl/glfw/GLFW;glfwShowWindow(J)V"))
	private void beamcraft$stayHidden(long handle) {
		if (!BeamCraftClient.HEADLESS) GLFW.glfwShowWindow(handle);
	}
}
