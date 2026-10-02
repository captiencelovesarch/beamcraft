package dev.captience.beamcraft.client;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.HitResult;
import net.minecraft.world.phys.Vec3;

/**
 * Minecraft's world is empty air, so its own raycast never hits BeamNG's ground.
 * BeamNG raycasts the crosshair against its world and sends the hit; when that is
 * nearer than anything Minecraft found, we hand Minecraft a hit on the air cell just
 * above the surface. Placing a block "clicks" a replaceable cell, so it goes right
 * there, sitting on the road.
 */
public final class TerrainAim {
	private static volatile double[] aim; // x, y, z, nx, ny, nz (MC coords)

	private TerrainAim() {}

	public static void set(double x, double y, double z, double nx, double ny, double nz) {
		aim = new double[] {x, y, z, nx, ny, nz};
	}

	public static void clear() {
		aim = null;
	}

	public static void apply(Minecraft mc) {
		double[] a = aim;
		if (a == null || mc.player == null || !BeamCraftClient.isControlling()) return;
		Vec3 eye = mc.player.getEyePosition();
		Vec3 hit = new Vec3(a[0], a[1], a[2]);
		double dist = eye.distanceTo(hit);
		if (dist > mc.player.blockInteractionRange()) return;
		HitResult current = mc.hitResult;
		if (current != null && current.getType() != HitResult.Type.MISS && eye.distanceTo(current.getLocation()) <= dist + 1e-3) {
			return;
		}
		Direction face = Direction.getApproximateNearest(a[3], a[4], a[5]);
		BlockPos cell = BlockPos.containing(a[0] + a[3] * 0.05, a[1] + a[4] * 0.05, a[2] + a[5] * 0.05);
		mc.hitResult = new BlockHitResult(hit, face, cell, false);
	}
}
