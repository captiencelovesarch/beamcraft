package dev.captience.beamcraft.mixin;

import dev.captience.beamcraft.TerrainColumns;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.CollisionGetter;
import net.minecraft.world.level.pathfinder.PathType;
import net.minecraft.world.level.pathfinder.PathfindingContext;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Mob pathfinding reads block states, and Minecraft's world here is empty air: without
 * this, mobs see BeamNG's ground as a bottomless drop and never path anywhere. Cells
 * under BeamNG's surface count as solid, so the cell above them is walkable.
 */
@Mixin(PathfindingContext.class)
public abstract class PathfindingContextMixin {
	@Shadow @Final private CollisionGetter level;

	@Inject(method = "getPathTypeFromState", at = @At("HEAD"), cancellable = true)
	private void beamcraft$terrainIsSolid(int x, int y, int z, CallbackInfoReturnable<PathType> cir) {
		if (!TerrainColumns.isEnabled() || !TerrainColumns.isSolidCell(x, y, z)) return;
		if (level.getBlockState(new BlockPos(x, y, z)).isAir()) cir.setReturnValue(PathType.BLOCKED);
	}
}
