package dev.captience.beamcraft;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import net.minecraft.util.Mth;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

/**
 * BeamNG's world, as collision. BeamNG raycasts a grid of columns around the player
 * and sends each column's surface height; every column becomes a box from that
 * height down {@link #DEPTH} metres. Small height steps between neighbouring columns
 * are climbed by vanilla step-up, tall ones act as walls.
 *
 * Shared by the client (player physics) and the integrated server (dropped items,
 * mobs) since both run in the same JVM, so it is fully concurrent.
 */
public final class TerrainColumns {
	public static final float NONE = -100000f;
	public static final double DEPTH = 1.5;

	private static final ConcurrentHashMap<Long, Float> HEIGHTS = new ConcurrentHashMap<>();
	private static volatile double res = 0.5;
	private static volatile boolean enabled;

	private TerrainColumns() {}

	public static void setEnabled(boolean on) {
		enabled = on;
	}

	public static boolean isEnabled() {
		return enabled;
	}

	public static int size() {
		return HEIGHTS.size();
	}

	public static void clear() {
		HEIGHTS.clear();
	}

	private static long key(int i, int k) {
		return ((long) i << 32) ^ (k & 0xFFFFFFFFL);
	}

	/** cells = flat i,k,h triples. */
	public static void put(double resolution, double[] cells) {
		if (resolution != res) {
			HEIGHTS.clear();
			res = resolution;
		}
		for (int n = 0; n + 2 < cells.length; n += 3) {
			HEIGHTS.put(key((int) cells[n], (int) cells[n + 1]), (float) cells[n + 2]);
		}
	}

	/** Known surface height of the column holding (x, z), or null. */
	public static Float heightAt(double x, double z) {
		return HEIGHTS.get(key(Mth.floor(x / res), Mth.floor(z / res)));
	}

	// BeamNG vehicles near the player, as boxes, replaced wholesale on every update
	private static volatile List<AABB> vehicleBoxes = List.of();

	public static void setVehicleBoxes(List<AABB> boxes) {
		vehicleBoxes = boxes;
	}

	/**
	 * BeamNG's surface at (x, z), bilinear between column centres: a ramp, not steps.
	 * Null if a neighbouring column is unknown or empty; if neighbours differ by more
	 * than a step (a wall, a kerb) the column's own height.
	 */
	public static Float smoothHeight(double x, double z) {
		double r = res;
		double fx = x / r - 0.5, fz = z / r - 0.5;
		int i = Mth.floor(fx), k = Mth.floor(fz);
		Float a = HEIGHTS.get(key(i, k)), b = HEIGHTS.get(key(i + 1, k)), c = HEIGHTS.get(key(i, k + 1)), d = HEIGHTS.get(key(i + 1, k + 1));
		Float own = heightAt(x, z);
		if (a == null || b == null || c == null || d == null) return own;
		if (a <= NONE + 1 || b <= NONE + 1 || c <= NONE + 1 || d <= NONE + 1) return own;
		float lo = Math.min(Math.min(a, b), Math.min(c, d)), hi = Math.max(Math.max(a, b), Math.max(c, d));
		if (hi - lo > STEP) return own;
		double tx = fx - i, tz = fz - k;
		return (float) Mth.lerp(tz, Mth.lerp(tx, a, b), Mth.lerp(tx, c, d));
	}

	/**
	 * Stick a walking entity to BeamNG's (smoothed) surface: up small rises and down
	 * small drops, so slopes walk like ramps. Call after the entity moved this tick.
	 */
	public static void keepOnGround(net.minecraft.world.entity.LivingEntity e, boolean wasOnGround) {
		if (!enabled || e.isNoGravity() || e.isInWater() || e.isPassenger() || e.isFallFlying()) return;
		var v = e.getDeltaMovement();
		if (v.y > 0.05) return; // jumping
		Float h = smoothHeight(e.getX(), e.getZ());
		if (h == null || h <= NONE + 1) return;
		double dy = h - e.getY();
		boolean up = dy > 0.001 && dy <= STEP;
		boolean down = wasOnGround && dy < -0.001 && dy >= -STEP;
		if (!up && !down) return;
		e.setPos(e.getX(), h, e.getZ());
		e.setDeltaMovement(v.x, 0, v.z);
		e.setOnGround(true);
		e.fallDistance = 0;
	}

	/** True once any ground under (x, z) is known. */
	public static boolean hasGroundAt(double x, double z) {
		Float h = HEIGHTS.get(key(Mth.floor(x / res), Mth.floor(z / res)));
		return h != null;
	}

	/**
	 * Whether block cell (x, y, z) is mostly below BeamNG's surface (for pathfinding,
	 * which only understands whole blocks). Unknown ground is not solid.
	 */
	public static boolean isSolidCell(int x, int y, int z) {
		Float h = heightAt(x + 0.5, z + 0.5);
		if (h == null || h <= NONE + 1) return false;
		return y + 0.5 < h && y + 1 > h - DEPTH;
	}

	/**
	 * BeamNG ground inside block cell pos, as a shape relative to the cell (for
	 * raycasts, which test one cell at a time). Empty if none.
	 */
	public static VoxelShape cellShape(int bx, int by, int bz) {
		if (!enabled || HEIGHTS.isEmpty()) return Shapes.empty();
		double r = res;
		VoxelShape out = Shapes.empty();
		int i0 = Mth.floor(bx / r), i1 = Mth.floor((bx + 1 - 1e-6) / r);
		int k0 = Mth.floor(bz / r), k1 = Mth.floor((bz + 1 - 1e-6) / r);
		for (int i = i0; i <= i1; i++) {
			for (int k = k0; k <= k1; k++) {
				Float h = HEIGHTS.get(key(i, k));
				if (h == null || h <= NONE + 1) continue;
				double top = Math.min(1, h - by), bottom = Math.max(0, h - DEPTH - by);
				if (top <= 0 || bottom >= 1 || top <= bottom) continue;
				double x0 = Math.max(0, i * r - bx), x1 = Math.min(1, (i + 1) * r - bx);
				double z0 = Math.max(0, k * r - bz), z1 = Math.min(1, (k + 1) * r - bz);
				out = Shapes.or(out, Shapes.box(x0, bottom, z0, x1, top, z1));
			}
		}
		return out;
	}

	public static boolean appliesTo(Level level) {
		return enabled && level.dimension() == Level.OVERWORLD;
	}

	/** Steps up to this high count as floor, not wall, for walking entities. */
	public static final double STEP = 0.6;

	public static List<VoxelShape> shapesFor(AABB box) {
		return shapesFor(box, Double.NaN);
	}

	/**
	 * feetY: the walking entity's feet, or NaN. BeamNG's slopes arrive as 0.5 m columns
	 * with flat tops, a staircase: walking into a 5 cm step every half metre cost Steve
	 * his speed on the slightest slope. Columns whose top is less than STEP above the
	 * feet stop at the feet instead (a floor, not a wall); keepOnGround() then lifts
	 * the entity onto the smoothed surface.
	 */
	public static List<VoxelShape> shapesFor(AABB box, double feetY) {
		if (!enabled) return List.of();
		List<VoxelShape> out = null;
		for (AABB v : vehicleBoxes) {
			if (v.intersects(box)) {
				if (out == null) out = new ArrayList<>();
				out.add(Shapes.create(v));
			}
		}
		if (HEIGHTS.isEmpty()) return out == null ? List.of() : out;
		double r = res;
		int i0 = Mth.floor(box.minX / r), i1 = Mth.floor(box.maxX / r);
		int k0 = Mth.floor(box.minZ / r), k1 = Mth.floor(box.maxZ / r);
		// a huge query box (explosions, big entities) would allocate a lot: cap it
		if ((long) (i1 - i0 + 1) * (k1 - k0 + 1) > 4096) return out == null ? List.of() : out;
		for (int i = i0; i <= i1; i++) {
			for (int k = k0; k <= k1; k++) {
				Float h = HEIGHTS.get(key(i, k));
				if (h == null || h <= NONE + 1) continue;
				double top = h, bottom = h - DEPTH;
				if (!Double.isNaN(feetY) && top > feetY && top <= feetY + STEP) top = Math.max(bottom + 0.01, feetY);
				if (top < box.minY || bottom > box.maxY) continue;
				if (out == null) out = new ArrayList<>();
				out.add(Shapes.create(i * r, bottom, k * r, (i + 1) * r, top, (k + 1) * r));
			}
		}
		return out == null ? List.of() : out;
	}
}
