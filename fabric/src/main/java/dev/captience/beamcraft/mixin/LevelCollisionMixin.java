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
	@Override
	public Iterable<VoxelShape> getBlockCollisionsFromContext(final CollisionContext source, final AABB box) {
		Level self = (Level) (Object) this;
		Iterable<VoxelShape> blocks = () -> new BlockCollisions<>(self, source, box, false, (p, shape) -> shape);
		if (!TerrainColumns.appliesTo(self)) return blocks;
		List<VoxelShape> terrain = TerrainColumns.shapesFor(box);
		return terrain.isEmpty() ? blocks : Iterables.concat(blocks, terrain);
	}
}
