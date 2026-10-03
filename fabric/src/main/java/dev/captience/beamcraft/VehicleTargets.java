package dev.captience.beamcraft;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.util.*;
import net.fabricmc.fabric.api.object.builder.v1.entity.FabricDefaultAttributeRegistry;
import net.minecraft.core.Registry;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.network.syncher.*;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.InteractionResult;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.*;
import net.minecraft.world.item.ItemStack;

/** Invisible combat targets; TerrainColumns supplies the actual solid car geometry. */
public final class VehicleTargets {
    public static final EntityType<Target> TYPE = Registry.register(BuiltInRegistries.ENTITY_TYPE,
        Identifier.fromNamespaceAndPath("beamcraft", "car_target"), EntityType.Builder.<Target>of(Target::new, MobCategory.MISC)
        .sized(1, 1).noSave().clientTrackingRange(8).updateInterval(1)
        .build(ResourceKey.create(Registries.ENTITY_TYPE, Identifier.fromNamespaceAndPath("beamcraft", "car_target"))));
    private record Box(int key, int vehicle, AABB bounds) {}
    private static volatile Map<Integer, Box> boxes = Map.of();
    private static volatile long received;
    private static final Map<Integer, Target> targets = new HashMap<>();
    public static void register() { FabricDefaultAttributeRegistry.register(TYPE, Mob.createMobAttributes().add(Attributes.MAX_HEALTH, 100000)); }
    public static void receive(JsonArray list) {
        Map<Integer, Box> next = new HashMap<>();
        if (list != null) for (var el : list) {
            JsonArray a = el.getAsJsonArray();
            if (a.size() != 8) continue;
            int key = a.get(0).getAsInt(), vehicle = a.get(1).getAsInt();
            next.put(key, new Box(key, vehicle, new AABB(a.get(2).getAsDouble(), a.get(3).getAsDouble(), a.get(4).getAsDouble(),
                a.get(5).getAsDouble(), a.get(6).getAsDouble(), a.get(7).getAsDouble())));
        }
        boxes = Map.copyOf(next); received = System.nanoTime();
    }
    public static void tick(MinecraftServer server) {
        var player = server.getPlayerList().getPlayers().stream().findFirst().orElse(null);
        Map<Integer, Box> current = Bridge.isConnected() && System.nanoTime() - received < 2_000_000_000L && player != null ? boxes : Map.of();
        for (var it = targets.entrySet().iterator(); it.hasNext();) {
            var e = it.next();
            if (!current.containsKey(e.getKey()) || e.getValue().isRemoved() || e.getValue().level() != player.level()) { e.getValue().discard(); it.remove(); }
        }
        if (player == null) return;
        ServerLevel level = (ServerLevel)player.level();
        for (Box box : current.values()) {
            Target t = targets.get(box.key);
            if (t == null) { t = new Target(TYPE, level); t.getEntityData().set(Target.KEY, box.key); targets.put(box.key, t); t.follow(box); level.addFreshEntity(t); }
            else t.follow(box);
        }
    }
    public static class Target extends Mob {
        static final EntityDataAccessor<Integer> KEY = SynchedEntityData.defineId(Target.class, EntityDataSerializers.INT);
        public Target(EntityType<? extends Mob> type, Level level) { super(type, level); setNoAi(true); setNoGravity(true); setInvisible(true); noPhysics = true; }
        @Override protected void defineSynchedData(SynchedEntityData.Builder builder) { super.defineSynchedData(builder); builder.define(KEY, -1); }
        void follow(Box b) { Vec3 c = b.bounds.getCenter(); setPos(c.x, b.bounds.minY, c.z); setBoundingBox(b.bounds); setDeltaMovement(Vec3.ZERO); }
        @Override public void tick() { super.tick(); Box b = boxes.get(getEntityData().get(KEY)); if (b != null) follow(b); }
        @Override public boolean isPickable() { return true; }
        @Override public float getPickRadius() { return 0.1f; }
        @Override public boolean isPushable() { return false; }
        @Override public boolean canBeCollidedWith(Entity e) { return false; }
        private Vec3 lastHit;

        @Override public boolean hurtServer(ServerLevel level, DamageSource source, float damage) {
            Box b = boxes.get(getEntityData().get(KEY));
            if (b == null) return false;
            boolean lightning = source.is(net.minecraft.tags.DamageTypeTags.IS_LIGHTNING);
            Entity attacker = source.getEntity();
            if (!lightning && !(attacker instanceof Player)) return false;
            // Let vanilla apply cooldowns, crit/enchantment effects and mace success handling.
            boolean hit = super.hurtServer(level, source, damage);
            setHealth(getMaxHealth());
            if (!hit) return false;
            Vec3 dir, point;
            if (lightning) {
                dir = new Vec3(0, -1, 0);
                point = new Vec3(b.bounds.getCenter().x, b.bounds.maxY, b.bounds.getCenter().z);
            } else {
                Entity direct = source.getDirectEntity();
                if (direct != null && direct != attacker) {
                    // arrows, tridents: along their flight, where they are
                    Vec3 v = direct.getDeltaMovement();
                    dir = v.lengthSqr() > 1e-6 ? v.normalize() : direct.getLookAngle();
                    point = direct.position();
                } else {
                    Player p = (Player) attacker;
                    dir = p.getLookAngle();
                    Vec3 eye = p.getEyePosition();
                    point = b.bounds.clip(eye, eye.add(dir.scale(6))).orElse(b.bounds.getCenter());
                }
            }
            lastHit = point;
            JsonObject m = new JsonObject(); m.addProperty("t", "vehHit"); m.addProperty("id", b.vehicle); m.addProperty("dmg", damage);
            m.addProperty("x", point.x); m.addProperty("y", point.y); m.addProperty("z", point.z);
            m.addProperty("dx", dir.x); m.addProperty("dy", dir.y); m.addProperty("dz", dir.z);
            // enchantments that act on the car itself (damage ones are already in dmg)
            ItemStack weapon = source.getWeaponItem();
            if (weapon != null && !weapon.isEmpty()) {
                var enchants = level.registryAccess().lookupOrThrow(Registries.ENCHANTMENT);
                int kb = net.minecraft.world.item.enchantment.EnchantmentHelper.getItemEnchantmentLevel(enchants.getOrThrow(net.minecraft.world.item.enchantment.Enchantments.KNOCKBACK), weapon)
                    + net.minecraft.world.item.enchantment.EnchantmentHelper.getItemEnchantmentLevel(enchants.getOrThrow(net.minecraft.world.item.enchantment.Enchantments.PUNCH), weapon);
                if (attacker instanceof Player p && p.isSprinting() && source.getDirectEntity() == p) kb++;
                if (kb > 0) m.addProperty("kb", kb);
                int fire = net.minecraft.world.item.enchantment.EnchantmentHelper.getItemEnchantmentLevel(enchants.getOrThrow(net.minecraft.world.item.enchantment.Enchantments.FIRE_ASPECT), weapon);
                if (fire > 0 && source.getDirectEntity() == attacker) m.addProperty("fire", fire);
            }
            if (source.getDirectEntity() != null && source.getDirectEntity() != attacker && source.getDirectEntity().isOnFire()) m.addProperty("fire", 1);
            if (source.is(net.minecraft.tags.DamageTypeTags.IS_FIRE)) m.addProperty("fire", 1);
            if (lightning) { m.addProperty("lightning", true); m.addProperty("fire", 2); }
            Bridge.send(m);
            return true;
        }

        @Override protected InteractionResult mobInteract(Player player, InteractionHand hand) {
            Box b = boxes.get(getEntityData().get(KEY));
            if (b == null) return InteractionResult.PASS;
            if (!level().isClientSide()) { JsonObject m = new JsonObject(); m.addProperty("t", "vehUse"); m.addProperty("id", b.vehicle); Bridge.send(m); }
            return InteractionResult.SUCCESS;
        }
    }
}
