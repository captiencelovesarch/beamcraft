package dev.captience.beamcraft.mixin;

import dev.captience.beamcraft.TerrainColumns;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.LevelReader;
import net.minecraft.world.phys.AABB;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * The server's anti-noclip check rejected every client step that ended slightly inside
 * a BeamNG ground column - on slopes that was every tick (walk, snap back, walk). The
 * client is the one walking on BeamNG's ground; trust it. (The server still needs the
 * ground itself: it applies gravity to its copy of Steve between packets, and items
 * are picked up there.)
 */
@Mixin(ServerGamePacketListenerImpl.class)
public abstract class ServerMoveCheckMixin {
	@Inject(method = "isEntityCollidingWithAnythingNew", at = @At("HEAD"), cancellable = true)
	private void beamcraft$trustClientOnGround(LevelReader level, Entity entity, AABB oldAABB, double x, double y, double z,
			CallbackInfoReturnable<Boolean> cir) {
		if (TerrainColumns.isEnabled() && entity instanceof Player) cir.setReturnValue(false);
	}
}
