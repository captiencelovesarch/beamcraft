package dev.captience.beamcraft;

import com.google.gson.JsonObject;
import java.util.List;
import net.minecraft.core.BlockPos;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.util.RandomSource;
import net.minecraft.world.Difficulty;
import net.minecraft.world.entity.EntitySpawnReason;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.Mob;
import net.minecraft.world.entity.ai.navigation.GroundPathNavigation;
import net.minecraft.world.entity.animal.Animal;
import net.minecraft.world.entity.monster.Enemy;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;

/**
 * Mobs living on BeamNG's ground.
 *
 * Minecraft's world is empty air, so vanilla's spawner never finds a valid spot and a
 * mob standing on ground BeamNG hasn't scanned yet would drop into the void. Here:
 * - walking mobs over unscanned ground are held still until BeamNG has sampled it
 *   (BeamNG samples around every mob it can see);
 * - a small spawner puts monsters out at night (not on Peaceful) and a few animals
 *   in daylight, on BeamNG's actual surface. It asks BeamNG for the ground height at
 *   a candidate spot ("probe") and spawns there once the answer is in.
 */
public final class MobSupport {
	public static final int MAX_MONSTERS = 6;
	public static final int MAX_ANIMALS = 4;
	private static final double RANGE = 48;

	private static int timer;
	private static double[] pending; // x, z, y-hint, ticks waited
	private static boolean pendingMonster;

	private MobSupport() {}

	public static void tick(MinecraftServer server) {
		if (!TerrainColumns.isEnabled() || !Bridge.isConnected()) return;
		ServerPlayer player = server.getPlayerList().getPlayers().stream().findFirst().orElse(null);
		if (player == null || player.level().dimension() != Level.OVERWORLD) return;
		ServerLevel level = player.level();
		holdUnscanned(level, player);
		if (Boolean.getBoolean("beamcraft.mobDebug") && timer % 100 == 0) debug(level, player);
		if (++timer % 20 == 0) spawnTick(level, player);
	}

	private static void debug(ServerLevel level, ServerPlayer player) {
		for (Mob mob : level.getEntitiesOfClass(Mob.class, player.getBoundingBox().inflate(64))) {
			var nav = mob.getNavigation();
			var path = nav.getPath();
			BeamCraft.LOG.info("mob {} at {} {} {} ground={} known={} target={} path={} done={} below={}",
				mob.getType().getDescriptionId(), String.format("%.1f", mob.getX()), String.format("%.2f", mob.getY()), String.format("%.1f", mob.getZ()),
				mob.onGround(), TerrainColumns.heightAt(mob.getX(), mob.getZ()), mob.getTarget() == null ? "-" : mob.getTarget().getName().getString(),
				path == null ? "null" : path.getNodeCount() + "@" + path.getNextNodeIndex(), nav.isDone(),
				net.minecraft.world.level.pathfinder.WalkNodeEvaluator.getPathTypeStatic(mob, mob.blockPosition().below()));
		}
	}

	private static void holdUnscanned(ServerLevel level, ServerPlayer player) {
		List<Mob> mobs = level.getEntitiesOfClass(Mob.class, player.getBoundingBox().inflate(128));
		for (Mob mob : mobs) {
			if (mob instanceof VehicleTargets.Target) continue;
			// fell through into the void below BeamNG's world: gone, like vanilla's void
			if (mob.getY() < player.getY() - 24 && !mob.onGround()) {
				mob.discard();
				continue;
			}
			if (mob.isNoGravity() || mob.isPassenger() || !(mob.getNavigation() instanceof GroundPathNavigation)) continue;
			if (mob.isInWater()) continue;
			Float top = TerrainColumns.heightAt(mob.getX(), mob.getZ());
			if (top == null) {
				// nothing known under it yet: undo this tick's fall until BeamNG has
				// sampled there. (Not the NoGravity flag: Minecraft saves that, and a
				// restart left mobs floating inside the ground for good.)
				Vec3 v = mob.getDeltaMovement();
				if (mob.getY() < mob.yo) mob.setPos(mob.getX(), mob.yo, mob.getZ());
				mob.setDeltaMovement(v.x * 0.5, Math.max(0, v.y), v.z * 0.5);
				mob.fallDistance = 0;
				continue;
			}
			// caught inside BeamNG's ground (it arrived under a mob that had already
			// dropped a little): collision never pushes out, so it would sink through.
			// Put it back on top.
			if (top > TerrainColumns.NONE + 1 && mob.getY() < top - 0.01 && mob.getY() > top - 4) {
				mob.setPos(mob.getX(), top + 0.001, mob.getZ());
				Vec3 v = mob.getDeltaMovement();
				mob.setDeltaMovement(v.x, Math.max(0, v.y), v.z);
				mob.fallDistance = 0;
			}
		}
	}

	/** Plays a Minecraft sound event in BeamNG at a position (set by the client). */
	public interface SoundSink {
		void play(net.minecraft.resources.Identifier event, double x, double y, double z, float volume, float pitch);
	}
	public static volatile SoundSink soundSink;

	/** A BeamNG car hit an entity: vehicle damage and a launch, like Steve gets. */
	public static void carHit(MinecraftServer server, int id, float dmg, double vx, double vy, double vz) {
		server.execute(() -> {
			for (ServerLevel level : server.getAllLevels()) {
				var e = level.getEntity(id);
				if (!(e instanceof net.minecraft.world.entity.LivingEntity le) || e instanceof VehicleTargets.Target) continue;
				var type = level.registryAccess().lookupOrThrow(net.minecraft.core.registries.Registries.DAMAGE_TYPE)
					.getOrThrow(net.minecraft.resources.ResourceKey.create(net.minecraft.core.registries.Registries.DAMAGE_TYPE,
						net.minecraft.resources.Identifier.fromNamespaceAndPath("beamcraft", "vehicle")));
				var source = new net.minecraft.world.damagesource.DamageSource(type);
				// vanilla only plays the hurt sound to players within 16 blocks of the
				// mob, which Steve usually isn't while you drive: BeamNG plays it instead
				boolean silent = le.isSilent();
				le.setSilent(true);
				boolean hit = le.hurtServer(level, source, dmg);
				le.setSilent(silent);
				le.setDeltaMovement(le.getDeltaMovement().add(vx / 20.0, vy / 20.0, vz / 20.0));
				le.hurtMarked = true;
				if (hit && !silent && soundSink != null) {
					var acc = (dev.captience.beamcraft.mixin.LivingEntitySounds) le;
					var ev = le.isDeadOrDying() ? acc.beamcraft$deathSound() : acc.beamcraft$hurtSound(source);
					if (ev != null) soundSink.play(ev.location(), le.getX(), le.getY() + le.getBbHeight() / 2, le.getZ(),
						acc.beamcraft$volume(), le.getVoicePitch());
				}
				return;
			}
		});
	}

	private static void spawnTick(ServerLevel level, ServerPlayer player) {
		RandomSource rnd = level.getRandom();
		if (pending != null) {
			Float h = TerrainColumns.heightAt(pending[0], pending[1]);
			if (h != null && h > TerrainColumns.NONE + 1 && Math.abs(h - pending[2]) < 16) {
				spawn(level, player, pending[0], h, pending[1], pendingMonster, rnd);
				pending = null;
			} else if (h != null || (pending[3] += 20) > 100) {
				pending = null; // nothing there (void, water...) or BeamNG never answered
			}
			return;
		}
		boolean night = level.isDarkOutside();
		boolean monsters = night && level.getDifficulty() != Difficulty.PEACEFUL;
		AABB box = player.getBoundingBox().inflate(RANGE);
		int count = monsters
			? level.getEntitiesOfClass(Mob.class, box, m -> m instanceof Enemy).size()
			: level.getEntitiesOfClass(Animal.class, box).size();
		if (count >= (monsters ? MAX_MONSTERS : MAX_ANIMALS)) return;
		// animals are rare, monsters keep coming at night
		if (rnd.nextFloat() > (monsters ? 0.5f : 0.08f)) return;
		double angle = rnd.nextDouble() * Math.PI * 2, dist = 16 + rnd.nextDouble() * 20;
		double x = player.getX() + Math.cos(angle) * dist, z = player.getZ() + Math.sin(angle) * dist;
		Float h = TerrainColumns.heightAt(x, z);
		if (h != null && h > TerrainColumns.NONE + 1) {
			if (Math.abs(h - player.getY()) < 16) spawn(level, player, x, h, z, monsters, rnd);
			return;
		}
		pending = new double[] {x, z, player.getY(), 0};
		pendingMonster = monsters;
		JsonObject m = new JsonObject();
		m.addProperty("t", "probe");
		m.addProperty("x", x);
		m.addProperty("y", player.getY());
		m.addProperty("z", z);
		Bridge.send(m);
	}

	private static void spawn(ServerLevel level, ServerPlayer player, double x, double y, double z, boolean monster, RandomSource rnd) {
		if (player.distanceToSqr(x, y, z) < 12 * 12) return;
		EntityType<? extends Mob> type;
		if (monster) {
			int r = rnd.nextInt(100);
			type = r < 35 ? net.minecraft.world.entity.EntityTypes.ZOMBIE : r < 60 ? net.minecraft.world.entity.EntityTypes.SKELETON : r < 80 ? net.minecraft.world.entity.EntityTypes.CREEPER : net.minecraft.world.entity.EntityTypes.SPIDER;
		} else {
			int r = rnd.nextInt(4);
			type = r == 0 ? net.minecraft.world.entity.EntityTypes.COW : r == 1 ? net.minecraft.world.entity.EntityTypes.PIG : r == 2 ? net.minecraft.world.entity.EntityTypes.SHEEP : net.minecraft.world.entity.EntityTypes.CHICKEN;
		}
		Mob mob = type.create(level, EntitySpawnReason.NATURAL);
		if (mob == null) return;
		mob.snapTo(x, y + 0.01, z, rnd.nextFloat() * 360f, 0f);
		if (!level.noCollision(mob)) return;
		BlockPos pos = BlockPos.containing(x, y, z);
		mob.finalizeSpawn(level, level.getCurrentDifficultyAt(pos), EntitySpawnReason.NATURAL, null);
		level.addFreshEntityWithPassengers(mob);
	}
}
