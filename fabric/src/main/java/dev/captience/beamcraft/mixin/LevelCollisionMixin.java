package dev.captience.beamcraft.mixin;

import com.google.common.collect.Iterables;
import dev.captience.beamcraft.TerrainColumns;
import java.util.List;
import net.minecraft.world.level.BlockCollisions;
import net.minecraft.world.level.CollisionGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.CollisionContext;
import net.minecraft.world.phys.shapes.VoxelShape;
import org.spongepowered.asm.mixin.Mixin;

/**
 * Adds BeamNG's terrain to every block-collision query in the overworld. This one
 * method feeds Entity.collide, step-up, onGround checks, sneaking edge detection and
 * noCollision, so the player (and items, mobs) treat BeamNG ground as solid.
 */
@Mixin(Level.class)
public abstract class LevelCollisionMixin implements CollisionGetter {
	/**
	 * Projectiles (wind charges, arrows, snowballs, pearls, tridents) find what they hit
	 * with this raycast, which only knows blocks: they flew through BeamNG's ground into
	 * the void and never burst. For projectile raycasts the ground counts. (Steve's own
	 * crosshair keeps the plain version; ground placement has its own path.)
	 */
	@Override
	public net.minecraft.world.phys.BlockHitResult clip(final net.minecraft.world.level.ClipContext c) {
		Level self = (Level) (Object) this;
		boolean terrain = false;
		if (TerrainColumns.appliesTo(self)
			&& ((ClipContextAccess) c).beamcraft$collisionContext() instanceof net.minecraft.world.phys.shapes.EntityCollisionContext ec
			&& ec.getEntity() instanceof net.minecraft.world.entity.projectile.Projectile) {
			terrain = true;
		}
		final boolean withTerrain = terrain;
		return net.minecraft.world.level.BlockGetter.traverseBlocks(c.getFrom(), c.getTo(), c, (context, pos) -> {
			var blockState = self.getBlockState(pos);
			var fluidState = self.getFluidState(pos);
			var from = context.getFrom();
			var to = context.getTo();
			VoxelShape blockShape = context.getBlockShape(blockState, self, pos);
			if (withTerrain) {
				VoxelShape ground = TerrainColumns.cellShape(pos.getX(), pos.getY(), pos.getZ());
				if (!ground.isEmpty()) blockShape = net.minecraft.world.phys.shapes.Shapes.or(blockShape, ground);
			}
			var blockResult = self.clipWithInteractionOverride(from, to, pos, blockShape, blockState);
			VoxelShape fluidShape = context.getFluidShape(fluidState, self, pos);
			var liquidResult = fluidShape.clip(from, to, pos);
			double b = blockResult == null ? Double.MAX_VALUE : context.getFrom().distanceToSqr(blockResult.getLocation());
			double l = liquidResult == null ? Double.MAX_VALUE : context.getFrom().distanceToSqr(liquidResult.getLocation());
			return b <= l ? blockResult : liquidResult;
		}, context -> {
			var delta = context.getFrom().subtract(context.getTo());
			return net.minecraft.world.phys.BlockHitResult.miss(context.getTo(),
				net.minecraft.core.Direction.getApproximateNearest(delta.x, delta.y, delta.z),
				net.minecraft.core.BlockPos.containing(context.getTo()));
		});
	}

	@Override
	public Iterable<VoxelShape> getBlockCollisionsFromContext(final CollisionContext source, final AABB box) {
		Level self = (Level) (Object) this;
		Iterable<VoxelShape> blocks = () -> new BlockCollisions<>(self, source, box, false, (p, shape) -> shape);
		if (!TerrainColumns.appliesTo(self)) return blocks;
		// The server's copy of Steve doesn't simulate movement (the client does), but its
		// "moved into a block" check rejected every step that ended slightly inside a
		// ground column - on slopes that was every tick: walk, snap back, walk.
		if (source instanceof net.minecraft.world.phys.shapes.EntityCollisionContext sc
			&& sc.getEntity() instanceof net.minecraft.server.level.ServerPlayer) return blocks;
		double feet = Double.NaN;
		if (source instanceof net.minecraft.world.phys.shapes.EntityCollisionContext ec
			&& ec.getEntity() instanceof net.minecraft.world.entity.LivingEntity le && !le.isFallFlying()) {
			feet = le.getY();
		}
		List<VoxelShape> terrain = TerrainColumns.shapesFor(box, feet);
		return terrain.isEmpty() ? blocks : Iterables.concat(blocks, terrain);
	}
}
