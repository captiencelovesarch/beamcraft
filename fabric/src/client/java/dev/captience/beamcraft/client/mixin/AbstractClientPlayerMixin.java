package dev.captience.beamcraft.client.mixin;

import dev.captience.beamcraft.client.CustomSkin;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.AbstractClientPlayer;
import net.minecraft.world.entity.player.PlayerSkin;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/** The local player wears the custom skin (see CustomSkin). */
@Mixin(AbstractClientPlayer.class)
public abstract class AbstractClientPlayerMixin {
	@Inject(method = "getSkin", at = @At("HEAD"), cancellable = true)
	private void beamcraft$customSkin(CallbackInfoReturnable<PlayerSkin> cir) {
		PlayerSkin custom = CustomSkin.get();
		if (custom == null) return;
		Minecraft mc = Minecraft.getInstance();
		AbstractClientPlayer self = (AbstractClientPlayer) (Object) this;
		if (self == mc.player || self.getUUID().equals(mc.getUser().getProfileId())) cir.setReturnValue(custom);
	}
}
