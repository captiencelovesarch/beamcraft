package dev.captience.beamcraft.mixin;

import dev.captience.beamcraft.TerrainColumns;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.ai.navigation.PathNavigation;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Wandering (random stroll, panic, tempt...) only accepts destinations standing on a
 * solid block, and under every spot here is air: passive mobs never found anywhere to
 * go. BeamNG's ground counts as solid footing.
 */
@Mixin(PathNavigation.class)
public abstract class PathNavigationMixin {
	@Inject(method = "isStableDestination", at = @At("HEAD"), cancellable = true)
	private void beamcraft$terrainIsStable(BlockPos pos, CallbackInfoReturnable<Boolean> cir) {
		if (TerrainColumns.isEnabled() && TerrainColumns.isSolidCell(pos.getX(), pos.getY() - 1, pos.getZ())) cir.setReturnValue(true);
	}
}
