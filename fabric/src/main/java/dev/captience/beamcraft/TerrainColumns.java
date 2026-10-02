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

	/** True once any ground under (x, z) is known. */
	public static boolean hasGroundAt(double x, double z) {
		Float h = HEIGHTS.get(key(Mth.floor(x / res), Mth.floor(z / res)));
		return h != null;
	}

	public static boolean appliesTo(Level level) {
		return enabled && level.dimension() == Level.OVERWORLD;
	}

	public static List<VoxelShape> shapesFor(AABB box) {
		if (!enabled || HEIGHTS.isEmpty()) return List.of();
		double r = res;
		int i0 = Mth.floor(box.minX / r), i1 = Mth.floor(box.maxX / r);
		int k0 = Mth.floor(box.minZ / r), k1 = Mth.floor(box.maxZ / r);
		// a huge query box (explosions, big entities) would allocate a lot: cap it
		if ((long) (i1 - i0 + 1) * (k1 - k0 + 1) > 4096) return List.of();
		List<VoxelShape> out = null;
		for (int i = i0; i <= i1; i++) {
			for (int k = k0; k <= k1; k++) {
				Float h = HEIGHTS.get(key(i, k));
				if (h == null || h <= NONE + 1) continue;
				double top = h, bottom = h - DEPTH;
				if (top < box.minY || bottom > box.maxY) continue;
				if (out == null) out = new ArrayList<>();
				out.add(Shapes.create(i * r, bottom, k * r, (i + 1) * r, top, (k + 1) * r));
			}
		}
		return out == null ? List.of() : out;
	}
}
