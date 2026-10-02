package dev.captience.beamcraft.mixin;

import dev.captience.beamcraft.BlockSync;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Every block change the server publishes is forwarded to BeamNG. */
@Mixin(ServerLevel.class)
public abstract class ServerLevelMixin {
	@Inject(method = "sendBlockUpdated", at = @At("HEAD"))
	private void beamcraft$onBlockUpdated(BlockPos pos, BlockState old, BlockState current, int flags, CallbackInfo ci) {
		if (old != current) BlockSync.onBlockUpdated((ServerLevel) (Object) this, pos, current);
	}
}
