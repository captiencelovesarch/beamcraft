package dev.captience.beamcraft.client;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import dev.captience.beamcraft.BlockSync;
import dev.captience.beamcraft.Bridge;
import dev.captience.beamcraft.TerrainColumns;
import dev.captience.beamcraft.client.mixin.KeyMappingAccessor;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.message.v1.ClientReceiveMessageEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.minecraft.SharedConstants;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Options;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.MinecraftServer;
import net.minecraft.sounds.SoundSource;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.item.BlockItem;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPreset;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.HitResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * The hidden client: Minecraft as BeamNG's player brain.
 *
 * BeamNG sends input, look angles, terrain columns and crosshair hits; we press the
 * matching keys, run vanilla's tick, and report back the player pose, HUD state and
 * every block change (with block models on first use). One Minecraft world per
 * BeamNG level, created on demand from the void "beamng" world preset.
 */
public class BeamCraftClient implements ClientModInitializer {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft");

	/** Set by tools/run_backend.sh: skip world rendering, never throttle. */
	public static final boolean HEADLESS = Boolean.getBoolean("beamcraft.headless");

	private static final ResourceKey<WorldPreset> PRESET =
		ResourceKey.create(Registries.WORLD_PRESET, Identifier.fromNamespaceAndPath("beamcraft", "beamng"));

	private static volatile boolean controlling;

	public static boolean isControlling() {
		return controlling;
	}

	// connection / session state (client thread only)
	private String beamLevel;
	private Path userPath;
	private String desiredWorld;
	private String currentWorld;
	private String openingWorld;
	private boolean readySent;
	private boolean freshWorld;
	private ModelExport export;
	private CompletableFuture<Void> atlasJob;
	private Path atlasDir;
	private boolean atlasSent;
	private final Set<Integer> sentStates = new HashSet<>();
	private String lastHud = "";
	private boolean awaitTerrain;
	private double[] enterTarget;
	private int awaitTicks;
	private boolean guiSent;
	private Path iconsDir;
	private String iconsUrl;
	private java.util.Iterator<String> iconBacklog;
	private boolean entsWereSent;

	// input from BeamNG
	private double inF, inB, inL, inR;
	private boolean inJump, inSneak, inSprint, inAttack, inUse;
	private float inYaw, inPitch;
	private boolean haveLook;

	@Override
	public void onInitializeClient() {
		LOG.info("BeamCraft client starting (headless={})", HEADLESS);
		Bridge.start();
		OverlayServer.start();
		ClientLifecycleEvents.CLIENT_STARTED.register(this::configure);
		ClientTickEvents.START_CLIENT_TICK.register(this::startTick);
		ClientTickEvents.END_CLIENT_TICK.register(this::endTick);
		ClientPlayConnectionEvents.JOIN.register((handler, sender, mc) -> onJoin(mc));
		ClientPlayConnectionEvents.DISCONNECT.register((handler, mc) -> onLeaveWorld());
		ClientReceiveMessageEvents.GAME.register((message, overlay) -> {
			if (!overlay) chat(message);
		});
		ClientReceiveMessageEvents.CHAT.register((message, signed, sender, params, ts) -> chat(message));
	}

	private void configure(Minecraft mc) {
		Options o = mc.options;
		o.pauseOnLostFocus = false;
		o.onboardAccessibility = false;
		o.tutorialStep = net.minecraft.client.tutorial.TutorialSteps.NONE;
		mc.getTutorial().setStep(net.minecraft.client.tutorial.TutorialSteps.NONE);
		if (HEADLESS) {
			o.renderDistance().set(6);
			o.simulationDistance().set(6);
		}
		// BeamNG has its own soundtrack; keep block and step sounds, drop the music
		o.getSoundSourceOptionInstance(SoundSource.MUSIC).set(0.0);
	}

	// ----------------------------------------------------------------------------
	// incoming
	// ----------------------------------------------------------------------------

	private void startTick(Minecraft mc) {
		JsonObject msg;
		while ((msg = Bridge.poll()) != null) {
			try {
				handle(mc, msg);
			} catch (RuntimeException e) {
				LOG.warn("Message {} failed", msg.has("t") ? msg.get("t").getAsString() : "?", e);
			}
		}
		// Vanilla holds the player frozen until the chunk under them has been compiled
		// for rendering. Headless never renders, so declare it compiled ourselves.
		if (HEADLESS && mc.getConnection() != null) {
			Runnable compiled = mc.getConnection().getPlayerCompiledSectionCallback();
			if (compiled != null) compiled.run();
		}
		applyOverlayInput(mc);
		applyInput(mc);
	}

	/**
	 * Mouse and keyboard from BeamNG's overlay page (only sent while a Minecraft screen is
	 * open), replayed through Minecraft's own GLFW handlers so every screen just works.
	 */
	private void applyOverlayInput(Minecraft mc) {
		JsonObject e;
		long handle = mc.getWindow().handle();
		var mouse = (dev.captience.beamcraft.client.mixin.MouseHandlerInvoker) mc.mouseHandler;
		var keys = (dev.captience.beamcraft.client.mixin.KeyboardHandlerInvoker) mc.keyboardHandler;
		while ((e = OverlayServer.INPUT.poll()) != null) {
			try {
				switch (e.get("t").getAsString()) {
					case "mm" -> mouse.beamcraft$onMove(handle, num(e, "x"), num(e, "y"));
					case "mb" -> {
						if (e.has("x")) mouse.beamcraft$onMove(handle, num(e, "x"), num(e, "y"));
						mouse.beamcraft$onButton(handle, new net.minecraft.client.input.MouseButtonInfo((int) num(e, "b"), (int) num(e, "m")), (int) num(e, "a"));
					}
					case "ms" -> mouse.beamcraft$onScroll(handle, num(e, "dx"), num(e, "dy"));
					case "key" -> keys.beamcraft$keyPress(handle, (int) num(e, "a"),
						new net.minecraft.client.input.KeyEvent((int) num(e, "k"), (int) num(e, "sc"), (int) num(e, "m")));
					case "ch" -> keys.beamcraft$charTyped(handle, new net.minecraft.client.input.CharacterEvent((int) num(e, "c")));
					case "full" -> OverlayServer.needFullFrame = true;
					default -> {
					}
				}
			} catch (RuntimeException ex) {
				LOG.debug("Overlay input {} failed: {}", e, ex.toString());
			}
		}
	}

	/**
	 * Size the hidden window to BeamNG's viewport (halved: Minecraft's GUI is pixel art,
	 * so rendering at half size and upscaling 2x looks the same and costs a quarter).
	 */
	private void applyViewport(Minecraft mc, int w, int h) {
		if (w <= 0 || h <= 0 || !HEADLESS) return;
		int k = 2;
		int ww = Math.max(320, w / k), wh = Math.max(240, h / k);
		int effective = Math.max(2, Math.round(h / 360f));
		int scale = Math.max(1, Math.round(effective / (float) k));
		mc.options.guiScale().set(scale);
		mc.getWindow().setWindowed(ww, wh);
		mc.resizeGui();
		LOG.info("Overlay {}x{} (BeamNG {}x{}), GUI scale {}", ww, wh, w, h, scale);
	}

	private void handle(Minecraft mc, JsonObject m) {
		String t = m.get("t").getAsString();
		switch (t) {
			case "_connect" -> {
				sentStates.clear();
				lastHud = "";
				atlasSent = false;
				readySent = false;
				guiSent = false;
				entsWereSent = false;
			}
			case "_disconnect" -> {
				release(mc);
				controlling = false;
			}
			case "hello" -> onHello(mc, m);
			case "leave" -> {
				release(mc);
				controlling = false;
			}
			case "enter" -> onEnter(mc, m);
			case "exit" -> {
				release(mc);
				controlling = false;
				TerrainAim.clear();
			}
			case "in" -> onInput(mc, m);
			case "ter" -> {
				JsonArray c = m.getAsJsonArray("c");
				double[] cells = new double[c.size()];
				for (int i = 0; i < cells.length; i++) cells[i] = c.get(i).getAsDouble();
				TerrainColumns.put(m.get("r").getAsDouble(), cells);
				TerrainColumns.setEnabled(true);
			}
			case "cmd" -> {
				if (mc.player != null) {
					String cmd = m.get("c").getAsString();
					if (cmd.startsWith("/")) cmd = cmd.substring(1);
					mc.player.connection.sendCommand(cmd);
				}
			}
			case "give" -> giveToSelected(mc, m.get("id").getAsString());
			case "viewport" -> applyViewport(mc, m.get("vw").getAsInt(), m.get("vh").getAsInt());
			case "hurt" -> onHurt(mc, m);
			case "veh" -> {
				java.util.List<net.minecraft.world.phys.AABB> boxes = new java.util.ArrayList<>();
				for (JsonElement e : m.getAsJsonArray("b")) {
					JsonArray a = e.getAsJsonArray();
					boxes.add(new net.minecraft.world.phys.AABB(a.get(0).getAsDouble(), a.get(1).getAsDouble(), a.get(2).getAsDouble(),
						a.get(3).getAsDouble(), a.get(4).getAsDouble(), a.get(5).getAsDouble()));
				}
				TerrainColumns.setVehicleBoxes(boxes);
			}
			default -> LOG.debug("Unknown message {}", t);
		}
	}

	private void onHello(Minecraft mc, JsonObject m) {
		beamLevel = m.has("level") ? m.get("level").getAsString() : "none";
		if (m.has("userPath")) userPath = Path.of(m.get("userPath").getAsString());
		if (m.has("vw") && m.has("vh")) applyViewport(mc, m.get("vw").getAsInt(), m.get("vh").getAsInt());
		// BeamNG's main menu has no level: no world either, so nothing can fall into the void
		desiredWorld = beamLevel.isEmpty() || beamLevel.equals("none") ? null : worldIdFor(beamLevel);
		readySent = false;
		LOG.info("BeamNG hello: level {}, userfolder {}", beamLevel, userPath);

		JsonObject w = new JsonObject();
		w.addProperty("t", "welcome");
		w.addProperty("mc", SharedConstants.getCurrentVersion().name());
		if (desiredWorld != null) w.addProperty("world", desiredWorld);
		Bridge.send(w);
		sendItemList();
	}

	private static String worldIdFor(String level) {
		String clean = level.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9_]+", "_");
		return "beamcraft_" + clean;
	}

	private void onEnter(Minecraft mc, JsonObject m) {
		LocalPlayer p = mc.player;
		if (p == null) return;
		double x = m.get("x").getAsDouble(), y = m.get("y").getAsDouble(), z = m.get("z").getAsDouble();
		float yaw = m.has("yaw") ? m.get("yaw").getAsFloat() : p.getYRot();
		TerrainColumns.clear();
		TerrainColumns.setEnabled(true);
		inYaw = yaw;
		inPitch = 0;
		haveLook = true;
		controlling = true;
		awaitTerrain = true;
		awaitTicks = 0;
		enterTarget = new double[] {x, y, z, yaw};
		p.setNoGravity(true);
		p.setDeltaMovement(0, 0, 0);
		teleport(mc, p, x, y, z, yaw);
		LOG.info("Entered BeamCraft at {} {} {}", x, y, z);
	}

	private void onInput(Minecraft mc, JsonObject m) {
		inF = num(m, "f");
		inB = num(m, "b");
		inL = num(m, "l");
		inR = num(m, "r");
		inJump = num(m, "j") > 0.5;
		inSneak = num(m, "s") > 0.5;
		inSprint = num(m, "sp") > 0.5;
		inAttack = num(m, "at") > 0.5;
		inUse = num(m, "us") > 0.5;
		if (m.has("yaw")) {
			inYaw = m.get("yaw").getAsFloat();
			inPitch = m.get("pitch").getAsFloat();
			haveLook = true;
		}
		if (m.has("aim") && m.get("aim").isJsonObject()) {
			JsonObject a = m.getAsJsonObject("aim");
			TerrainAim.set(num(a, "x"), num(a, "y"), num(a, "z"), num(a, "nx"), num(a, "ny"), num(a, "nz"));
		} else {
			TerrainAim.clear();
		}
		if (m.has("ev")) {
			for (JsonElement e : m.getAsJsonArray("ev")) onEvent(mc, e.getAsJsonObject());
		}
	}

	private void onEvent(Minecraft mc, JsonObject e) {
		String k = e.get("k").getAsString();
		Options o = mc.options;
		LocalPlayer p = mc.player;
		switch (k) {
			case "attack" -> click(o.keyAttack);
			case "use" -> click(o.keyUse);
			case "pick" -> click(o.keyPickItem);
			case "drop" -> click(o.keyDrop);
			case "inventory" -> click(o.keyInventory);
			case "chat" -> click(o.keyChat);
			case "command" -> click(o.keyCommand);
			case "view" -> click(o.keyTogglePerspective);
			case "slot" -> {
				if (p != null) p.getInventory().setSelectedSlot(Math.floorMod((int) num(e, "n"), 9));
			}
			case "scroll" -> {
				if (p != null) {
					Inventory inv = p.getInventory();
					inv.setSelectedSlot(Math.floorMod(inv.getSelectedSlot() + (int) num(e, "n"), 9));
				}
			}
			default -> {
			}
		}
	}

	private static void click(KeyMapping key) {
		KeyMappingAccessor acc = (KeyMappingAccessor) key;
		acc.beamcraft$setClickCount(acc.beamcraft$getClickCount() + 1);
	}

	private static double num(JsonObject o, String key) {
		JsonElement e = o.get(key);
		return e == null || e.isJsonNull() ? 0 : e.getAsDouble();
	}

	private void applyInput(Minecraft mc) {
		LocalPlayer p = mc.player;
		if (p == null) return;
		if (!controlling) {
			// nobody is playing Steve: keep him exactly where he is, no falling into the void
			p.setNoGravity(true);
			p.setDeltaMovement(0, 0, 0);
			p.fallDistance = 0;
			return;
		}
		if (!awaitTerrain && p.isNoGravity()) p.setNoGravity(false);
		Options o = mc.options;
		o.keyUp.setDown(inF > 0.5);
		o.keyDown.setDown(inB > 0.5);
		o.keyLeft.setDown(inL > 0.5);
		o.keyRight.setDown(inR > 0.5);
		o.keyJump.setDown(inJump);
		o.keyShift.setDown(inSneak);
		o.keySprint.setDown(inSprint);
		o.keyAttack.setDown(inAttack);
		o.keyUse.setDown(inUse);
		if (haveLook) {
			p.setYRot(inYaw);
			p.setXRot(Math.max(-90f, Math.min(90f, inPitch)));
			p.yRotO = p.getYRot();
			p.xRotO = p.getXRot();
		}
		// hold Steve in place until he is where BeamNG put him and BeamNG has told us
		// what is under his feet
		if (awaitTerrain) {
			p.setDeltaMovement(0, 0, 0);
			awaitTicks++;
			double[] t = enterTarget;
			boolean arrived = t == null || p.distanceToSqr(t[0], t[1], t[2]) < 0.25;
			if (!arrived && awaitTicks % 10 == 0) teleport(mc, p, t[0], t[1], t[2], (float) t[3]);
			Float h = TerrainColumns.heightAt(p.getX(), p.getZ());
			boolean groundUnderFeet = h != null && h > TerrainColumns.NONE + 1 && h <= p.getY() + 0.6 && h >= p.getY() - 1.5;
			boolean loaded = mc.getConnection() != null && mc.getConnection().hasClientLoaded();
			if (arrived && loaded && TerrainColumns.size() > 50 && (groundUnderFeet || awaitTicks > 100)) {
				awaitTerrain = false;
				enterTarget = null;
				p.setNoGravity(false);
			}
		}
	}

	private void teleport(Minecraft mc, LocalPlayer p, double x, double y, double z, float yaw) {
		p.snapTo(x, y, z, yaw, 0f);
		runServerCommand(mc, String.format(Locale.ROOT, "tp %s %.3f %.3f %.3f %.2f 0", p.getGameProfile().name(), x, y, z, yaw));
	}

	private void release(Minecraft mc) {
		Options o = mc.options;
		for (KeyMapping k : new KeyMapping[] {o.keyUp, o.keyDown, o.keyLeft, o.keyRight, o.keyJump, o.keyShift, o.keySprint, o.keyAttack, o.keyUse}) {
			k.setDown(false);
		}
		inF = inB = inL = inR = 0;
		inJump = inSneak = inSprint = inAttack = inUse = false;
		if (mc.player != null && awaitTerrain) mc.player.setNoGravity(false);
		awaitTerrain = false;
	}

	// ----------------------------------------------------------------------------
	// outgoing
	// ----------------------------------------------------------------------------

	private void endTick(Minecraft mc) {
		manageWorld(mc);
		if (!Bridge.isConnected()) return;
		manageAtlas(mc);
		manageGui(mc);
		LocalPlayer p = mc.player;
		if (p != null && currentWorld != null) {
			sendPose(mc, p);
			sendHud(mc, p);
			sendEntities(mc, p);
		}
		flushBlocks();
	}

	private void sendPose(Minecraft mc, LocalPlayer p) {
		StringBuilder sb = new StringBuilder(160);
		sb.append("{\"t\":\"p\",\"x\":").append(r4(p.getX()))
			.append(",\"y\":").append(r4(p.getY()))
			.append(",\"z\":").append(r4(p.getZ()))
			.append(",\"yaw\":").append(r4(p.getYRot()))
			.append(",\"pitch\":").append(r4(p.getXRot()))
			.append(",\"eye\":").append(r4(p.getEyeHeight()))
			.append(",\"g\":").append(p.onGround() ? 1 : 0)
			.append(",\"by\":").append(r4(p.yBodyRot))
			.append(",\"hy\":").append(r4(p.yHeadRot))
			.append(",\"lp\":").append(r4(p.walkAnimation.position(1f)))
			.append(",\"ls\":").append(r4(p.walkAnimation.speed(1f)))
			.append(",\"sw\":").append(r4(p.getAttackAnim(1f)))
			.append(",\"cr\":").append(p.isCrouching() ? 1 : 0)
			.append(",\"scr\":").append(mc.gui.screen() != null ? 1 : 0)
			.append(",\"cam\":").append(mc.options.getCameraType().ordinal());
		ItemStack held = p.getMainHandItem();
		if (!held.isEmpty()) {
			String hid = BuiltInRegistries.ITEM.getKey(held.getItem()).toString();
			sb.append(",\"held\":\"").append(hid).append('"');
			if (iconsDir != null) GuiExport.ensureIcon(mc, iconsDir, hid);
			if (held.getItem() instanceof BlockItem bi && bi.getBlock().defaultBlockState().isSolidRender()) {
				sb.append(",\"hs\":").append(stateForBeamNG(Block.getId(bi.getBlock().defaultBlockState())));
			}
		}
		HitResult hr = mc.hitResult;
		if (hr instanceof BlockHitResult bhr && hr.getType() == HitResult.Type.BLOCK && mc.level != null
			&& !mc.level.getBlockState(bhr.getBlockPos()).isAir()) {
			BlockPos bp = bhr.getBlockPos();
			sb.append(",\"tgt\":[").append(bp.getX()).append(',').append(bp.getY()).append(',').append(bp.getZ()).append(']');
		}
		sb.append('}');
		Bridge.sendLine(sb.toString());
	}

	private void sendHud(Minecraft mc, LocalPlayer p) {
		Inventory inv = p.getInventory();
		JsonObject h = new JsonObject();
		h.addProperty("t", "hud");
		h.addProperty("sel", inv.getSelectedSlot());
		JsonArray bar = new JsonArray();
		for (int i = 0; i < 9; i++) {
			ItemStack st = inv.getItem(i);
			JsonObject it = new JsonObject();
			String iid = BuiltInRegistries.ITEM.getKey(st.getItem()).toString();
			it.addProperty("id", iid);
			if (iconsDir != null && !st.isEmpty()) GuiExport.ensureIcon(mc, iconsDir, iid);
			it.addProperty("n", st.getCount());
			bar.add(it);
		}
		h.add("bar", bar);
		h.addProperty("hp", Math.round(p.getHealth() * 10f) / 10f);
		h.addProperty("food", p.getFoodData().getFoodLevel());
		h.addProperty("gm", mc.gameMode != null ? mc.gameMode.getPlayerMode().getName() : "survival");
		h.addProperty("xp", Math.round(p.experienceProgress * 100f) / 100f);
		h.addProperty("lvl", p.experienceLevel);
		h.addProperty("air", p.getAirSupply());
		h.addProperty("armor", p.getArmorValue());
		String s = h.toString();
		if (!s.equals(lastHud)) {
			lastHud = s;
			Bridge.sendLine(s);
		}
	}

	private void sendItemList() {
		JsonObject o = new JsonObject();
		o.addProperty("t", "items");
		JsonArray blocks = new JsonArray();
		JsonArray other = new JsonArray();
		for (Item item : BuiltInRegistries.ITEM) {
			String id = BuiltInRegistries.ITEM.getKey(item).toString();
			if (id.equals("minecraft:air")) continue;
			(item instanceof BlockItem ? blocks : other).add(id);
		}
		o.add("blocks", blocks);
		o.add("other", other);
		Bridge.send(o);
	}

	private static String r4(double d) {
		return Double.toString(Math.round(d * 10000.0) / 10000.0);
	}

	private void chat(Component message) {
		if (!Bridge.isConnected()) return;
		JsonObject o = new JsonObject();
		o.addProperty("t", "chat");
		o.addProperty("m", message.getString());
		Bridge.send(o);
	}

	/** Forward queued block changes, defining any block state BeamNG hasn't seen yet. */
	private void flushBlocks() {
		if (export == null) return; // models not scanned yet: keep changes queued
		int budget = 30000;
		StringBuilder blocks = null;
		JsonArray defs = null;
		int[] c;
		while (budget-- > 0 && (c = BlockSync.CHANGES.poll()) != null) {
			int id = c[3];
			if (id != 0 && sentStates.add(id)) {
				if (defs == null) defs = new JsonArray();
				defs.add(export.stateDef(id));
			}
			if (blocks == null) blocks = new StringBuilder("{\"t\":\"blocks\",\"l\":[");
			else blocks.append(',');
			// air of any kind is "0" to BeamNG
			int sendId = Block.stateById(id).isAir() ? 0 : id;
			blocks.append(c[0]).append(',').append(c[1]).append(',').append(c[2]).append(',').append(sendId);
		}
		if (defs != null) {
			JsonObject d = new JsonObject();
			d.addProperty("t", "states");
			d.add("d", defs);
			Bridge.send(d);
		}
		if (blocks != null) Bridge.sendLine(blocks.append("]}").toString());
	}

	private void manageAtlas(Minecraft mc) {
		if (atlasSent || userPath == null || mc.gui.overlay() != null) return;
		if (export == null) export = ModelExport.build(mc);
		Path dir = userPath.resolve("beamcraft").resolve("atlas");
		if (atlasJob == null || !dir.equals(atlasDir)) {
			atlasDir = dir;
			ModelExport ex = export;
			atlasJob = CompletableFuture.runAsync(() -> {
				try {
					ex.writePages(mc.getResourceManager(), dir);
				} catch (Exception e) {
					LOG.error("Atlas write failed", e);
				}
			});
		}
		if (atlasJob.isDone()) {
			JsonObject a = new JsonObject();
			a.addProperty("t", "atlas");
			a.addProperty("dir", "/beamcraft/atlas");
			a.addProperty("hash", export.hash());
			a.addProperty("pages", export.pages());
			Bridge.send(a);
			atlasSent = true;
		}
	}

	/** Block state id BeamNG can draw, sending its definition first if needed. */
	private int stateForBeamNG(int id) {
		if (export != null && sentStates.add(id)) {
			JsonObject d = new JsonObject();
			d.addProperty("t", "states");
			JsonArray defs = new JsonArray();
			defs.add(export.stateDef(id));
			d.add("d", defs);
			Bridge.send(d);
		}
		return id;
	}

	/** Items, falling blocks, primed TNT, xp and mobs near Steve, so BeamNG can draw them. */
	private void sendEntities(Minecraft mc, LocalPlayer p) {
		if (mc.level == null) return;
		StringBuilder sb = new StringBuilder("{\"t\":\"ents\",\"l\":[");
		int n = 0;
		for (net.minecraft.world.entity.Entity e : mc.level.getEntities(p, p.getBoundingBox().inflate(64))) {
			String kind;
			String extra;
			if (e instanceof net.minecraft.world.entity.item.ItemEntity ie) {
				kind = "i";
				extra = '"' + BuiltInRegistries.ITEM.getKey(ie.getItem().getItem()).toString() + '"';
				if (iconsDir != null) GuiExport.ensureIcon(mc, iconsDir, BuiltInRegistries.ITEM.getKey(ie.getItem().getItem()).toString());
			} else if (e instanceof net.minecraft.world.entity.item.FallingBlockEntity fb) {
				kind = "b";
				extra = Integer.toString(stateForBeamNG(Block.getId(fb.getBlockState())));
			} else if (e instanceof net.minecraft.world.entity.item.PrimedTnt tnt) {
				kind = "b";
				extra = Integer.toString(stateForBeamNG(Block.getId(tnt.getBlockState())));
			} else if (e instanceof net.minecraft.world.entity.ExperienceOrb) {
				kind = "x";
				extra = "0";
			} else if (e instanceof net.minecraft.world.entity.LivingEntity) {
				kind = "m";
				extra = '"' + BuiltInRegistries.ENTITY_TYPE.getKey(e.getType()).toString() + '"';
			} else {
				continue;
			}
			if (n++ > 0) sb.append(',');
			sb.append('[').append(e.getId()).append(",\"").append(kind).append("\",")
				.append(r4(e.getX())).append(',').append(r4(e.getY())).append(',').append(r4(e.getZ())).append(',')
				.append(r4(e.getYRot())).append(',').append(r4(e.getBbWidth())).append(',').append(r4(e.getBbHeight())).append(',')
				.append(extra).append(']');
		}
		if (n == 0 && !entsWereSent) return;
		entsWereSent = n > 0;
		Bridge.sendLine(sb.append("]}").toString());
	}

	/** A BeamNG vehicle hit Steve: knock him back and hurt him (creative ignores the damage). */
	private void onHurt(Minecraft mc, JsonObject m) {
		LocalPlayer p = mc.player;
		if (p == null) return;
		p.setDeltaMovement(p.getDeltaMovement().add(num(m, "vx") / 20.0, num(m, "vy") / 20.0, num(m, "vz") / 20.0));
		float dmg = (float) num(m, "dmg");
		MinecraftServer server = mc.getSingleplayerServer();
		if (server == null || dmg <= 0) return;
		java.util.UUID uuid = p.getUUID();
		server.execute(() -> {
			net.minecraft.server.level.ServerPlayer sp = server.getPlayerList().getPlayer(uuid);
			if (sp == null) return;
			net.minecraft.server.level.ServerLevel lvl = sp.level();
			var type = lvl.registryAccess().lookupOrThrow(Registries.DAMAGE_TYPE)
				.getOrThrow(ResourceKey.create(Registries.DAMAGE_TYPE, Identifier.fromNamespaceAndPath("beamcraft", "vehicle")));
			sp.hurtServer(lvl, new net.minecraft.world.damagesource.DamageSource(type), dmg);
		});
	}

	/** HUD sprites, font, skin; then every item icon a few per tick for the picker. */
	private void manageGui(Minecraft mc) {
		if (export == null || userPath == null || !atlasSent) return;
		if (!guiSent) {
			guiSent = true;
			try {
				Path guiDir = userPath.resolve("beamcraft").resolve("gui");
				Bridge.send(GuiExport.writeHud(mc, guiDir, export.hash()));
			} catch (Exception e) {
				LOG.error("GUI export failed", e);
			}
			iconsDir = userPath.resolve("beamcraft").resolve("icons").resolve(export.hash());
			iconsUrl = "/beamcraft/icons/" + export.hash();
			JsonObject ic = new JsonObject();
			ic.addProperty("t", "icons");
			ic.addProperty("dir", iconsUrl);
			ic.addProperty("done", false);
			Bridge.send(ic);
			iconBacklog = GuiExport.allItemIds().iterator();
		}
		if (iconBacklog != null) {
			long until = System.nanoTime() + 8_000_000L; // 8 ms per tick
			while (iconBacklog.hasNext() && System.nanoTime() < until) GuiExport.ensureIcon(mc, iconsDir, iconBacklog.next());
			if (!iconBacklog.hasNext()) {
				iconBacklog = null;
				JsonObject ic = new JsonObject();
				ic.addProperty("t", "icons");
				ic.addProperty("dir", iconsUrl);
				ic.addProperty("done", true);
				Bridge.send(ic);
			}
		}
	}

	// ----------------------------------------------------------------------------
	// worlds
	// ----------------------------------------------------------------------------

	private void manageWorld(Minecraft mc) {
		if (mc.gui.overlay() != null) return;
		if (desiredWorld == null) {
			if (mc.level != null && currentWorld != null && openingWorld == null && beamLevel != null) {
				LOG.info("BeamNG has no level loaded: leaving {}", currentWorld);
				controlling = false;
				currentWorld = null;
				mc.disconnectWithSavingScreen();
				mc.gui.setScreen(new TitleScreen());
			}
			return;
		}
		if (mc.level != null) {
			if (desiredWorld.equals(currentWorld)) {
				boolean loaded = mc.getConnection() != null && mc.getConnection().hasClientLoaded() && mc.player != null;
				if (!readySent && loaded && Bridge.isConnected()) {
					readySent = true;
					JsonObject r = new JsonObject();
					r.addProperty("t", "ready");
					r.addProperty("world", currentWorld);
					Bridge.send(r);
					JsonObject clear = new JsonObject();
					clear.addProperty("t", "clear");
					Bridge.send(clear);
					sentStates.clear();
					BlockSync.CHANGES.clear();
					BlockSync.requestFullSync();
					if (freshWorld) {
						freshWorld = false;
						starterKit(mc);
					}
				}
			} else if (openingWorld == null && currentWorld != null) {
				LOG.info("Switching worlds: {} -> {}", currentWorld, desiredWorld);
				JsonObject u = new JsonObject();
				u.addProperty("t", "unready");
				Bridge.send(u);
				controlling = false;
				currentWorld = null;
				mc.disconnectWithSavingScreen();
				mc.gui.setScreen(new TitleScreen());
			}
			return;
		}
		if (openingWorld != null) return;
		openingWorld = desiredWorld;
		try {
			if (mc.getLevelSource().levelExists(desiredWorld)) {
				LOG.info("Opening world {}", desiredWorld);
				freshWorld = false;
				mc.createWorldOpenFlows().openWorld(desiredWorld, () -> openingWorld = null);
			} else {
				LOG.info("Creating world {}", desiredWorld);
				freshWorld = true;
				LevelSettings settings = new LevelSettings("BeamCraft " + beamLevel, GameType.CREATIVE,
					LevelSettings.DifficultySettings.DEFAULT, true, WorldDataConfiguration.DEFAULT);
				mc.createWorldOpenFlows().createFreshLevel(desiredWorld, settings, new WorldOptions(0L, false, false),
					registries -> registries.lookupOrThrow(Registries.WORLD_PRESET).getOrThrow(PRESET).value().createWorldDimensions(),
					new TitleScreen());
			}
		} catch (RuntimeException e) {
			LOG.error("Could not open world {}", desiredWorld, e);
			openingWorld = null;
		}
	}

	private void onJoin(Minecraft mc) {
		if (openingWorld != null) {
			currentWorld = openingWorld;
			openingWorld = null;
		}
		readySent = false;
		LOG.info("Joined world {}", currentWorld);
	}

	private void onLeaveWorld() {
		controlling = false;
		currentWorld = null;
		TerrainColumns.clear();
	}

	/** A first hotbar so there is something to build with right away. */
	private void starterKit(Minecraft mc) {
		String[] kit = {"stone", "grass_block", "oak_planks", "cobblestone", "glass", "bricks", "oak_log", "sand", "tnt"};
		String name = mc.player != null ? mc.player.getGameProfile().name() : "@a";
		for (int i = 0; i < kit.length; i++) {
			runServerCommand(mc, "item replace entity " + name + " hotbar." + i + " with minecraft:" + kit[i] + " 64");
		}
	}

	private void giveToSelected(Minecraft mc, String itemId) {
		LocalPlayer p = mc.player;
		if (p == null || mc.gameMode == null) return;
		Item item = BuiltInRegistries.ITEM.getValue(Identifier.parse(itemId));
		ItemStack stack = new ItemStack(item, item.getDefaultMaxStackSize());
		int slot = p.getInventory().getSelectedSlot();
		p.getInventory().setItem(slot, stack);
		mc.gameMode.handleCreativeModeItemAdd(stack, 36 + slot);
	}

	private static void runServerCommand(Minecraft mc, String command) {
		MinecraftServer server = mc.getSingleplayerServer();
		if (server == null) return;
		server.execute(() -> {
			try {
				server.getCommands().performPrefixedCommand(server.createCommandSourceStack().withSuppressedOutput(), command);
			} catch (RuntimeException e) {
				LOG.warn("Command '{}' failed: {}", command, e.getMessage());
			}
		});
	}
}
