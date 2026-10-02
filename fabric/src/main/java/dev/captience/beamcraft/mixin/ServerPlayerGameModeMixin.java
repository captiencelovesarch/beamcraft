package dev.captience.beamcraft.mixin;

import dev.captience.beamcraft.BeamCraft;
import dev.captience.beamcraft.TerrainColumns;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.level.ServerPlayerGameMode;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.InteractionResult;
import net.minecraft.world.item.BlockItem;
import net.minecraft.world.item.BucketItem;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.BlockHitResult;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Placing onto BeamNG ground "clicks" an air cell (see TerrainAim). Before vanilla
 * handles that click, drop a ground anchor into the cell holding the terrain surface
 * so the placed block has something to stand on.
 */
@Mixin(ServerPlayerGameMode.class)
public abstract class ServerPlayerGameModeMixin {
	@Inject(method = "useItemOn", at = @At("HEAD"))
	private void beamcraft$anchorOnTerrain(ServerPlayer player, Level level, ItemStack stack, InteractionHand hand,
		BlockHitResult hit, CallbackInfoReturnable<InteractionResult> cir) {
		if (level.dimension() != Level.OVERWORLD || !TerrainColumns.isEnabled()) return;
		if (!(stack.getItem() instanceof BlockItem) && !(stack.getItem() instanceof BucketItem)) return;
		BlockPos pos = hit.getBlockPos();
		if (!level.getBlockState(pos).isAir()) return;
		BlockPos below = pos.below();
		if (!level.getBlockState(below).isAir()) return;
		Float h = TerrainColumns.heightAt(pos.getX() + 0.5, pos.getZ() + 0.5);
		if (h == null || h <= TerrainColumns.NONE + 1) return;
		// the surface must lie in (or just under) the cell below the placement
		if (h < pos.getY() - 1.5 || h > pos.getY() + 0.6) return;
		level.setBlock(below, BeamCraft.GROUND_ANCHOR.defaultBlockState(), 3);
	}
}
