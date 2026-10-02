package dev.captience.beamcraft.client.mixin;

import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.resource.GraphicsResourceAllocator;
import dev.captience.beamcraft.client.BeamCraftClient;
import dev.captience.beamcraft.client.OverlayCapture;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.renderer.GameRenderer;
import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import org.joml.Matrix4fc;
import org.joml.Vector4f;
import org.joml.Vector4fc;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.ModifyArg;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * The hidden client draws everything *except* the world, over a transparent
 * background: the first-person hand, screen effects (fire, water, hurt tint, portal),
 * and the whole GUI. BeamNG draws the world; this frame is copied off the GPU and
 * laid over BeamNG's picture (see OverlayCapture).
 */
@Mixin(GameRenderer.class)
public abstract class GameRendererMixin {
	@Unique
	private static final Vector4fc beamcraft$TRANSPARENT = new Vector4f(0f, 0f, 0f, 0f);

	@Redirect(method = "renderLevel", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/LevelRenderer;render(Lcom/mojang/blaze3d/resource/GraphicsResourceAllocator;Lnet/minecraft/client/DeltaTracker;ZLnet/minecraft/client/renderer/state/level/CameraRenderState;Lorg/joml/Matrix4fc;Lcom/mojang/blaze3d/buffers/GpuBufferSlice;Lorg/joml/Vector4f;Z)V"))
	private void beamcraft$skipWorld(LevelRenderer renderer, GraphicsResourceAllocator allocator, DeltaTracker deltaTracker,
		boolean renderOutline, CameraRenderState cameraState, Matrix4fc modelView, GpuBufferSlice fog, Vector4f fogColor, boolean sky) {
		if (!BeamCraftClient.HEADLESS) renderer.render(allocator, deltaTracker, renderOutline, cameraState, modelView, fog, fogColor, sky);
	}

	@ModifyArg(method = "render", at = @At(value = "INVOKE",
		target = "Lcom/mojang/blaze3d/systems/CommandEncoder;clearColorAndDepthTextures(Lcom/mojang/blaze3d/textures/GpuTexture;Lorg/joml/Vector4fc;Lcom/mojang/blaze3d/textures/GpuTexture;D)V"),
		index = 1)
	private Vector4fc beamcraft$transparentClear(Vector4fc color) {
		return BeamCraftClient.HEADLESS ? beamcraft$TRANSPARENT : color;
	}

	@Inject(method = "render", at = @At("TAIL"))
	private void beamcraft$capture(DeltaTracker deltaTracker, boolean advanceGameTime, CallbackInfo ci) {
		OverlayCapture.afterFrame(((GameRenderer) (Object) this).mainRenderTarget());
	}
}
