package dev.captience.beamcraft;

import net.minecraft.core.BlockPos;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.RenderShape;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.shapes.CollisionContext;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

/**
 * Stands in for BeamNG's ground under anything placed on it.
 *
 * Minecraft's world under BeamNG terrain is empty air, so redstone dust, torches,
 * flowers, doors and rails had nothing to sit on and sand fell into the void. An
 * anchor goes in the cell below such a placement: invisible, no collision (Steve
 * already stands on the real terrain), not targetable, unbreakable, but with a full
 * support shape, so every "is the block below sturdy?" check says yes. It is tagged
 * as dirt so plants take root in it too.
 */
public class GroundAnchorBlock extends Block {
	public GroundAnchorBlock(Properties properties) {
		super(properties);
	}

	@Override
	protected RenderShape getRenderShape(BlockState state) {
		return RenderShape.INVISIBLE;
	}

	@Override
	protected VoxelShape getShape(BlockState state, BlockGetter level, BlockPos pos, CollisionContext context) {
		return Shapes.empty();
	}

	@Override
	protected VoxelShape getCollisionShape(BlockState state, BlockGetter level, BlockPos pos, CollisionContext context) {
		return Shapes.empty();
	}

	@Override
	protected VoxelShape getBlockSupportShape(BlockState state, BlockGetter level, BlockPos pos) {
		return Shapes.block();
	}
}
