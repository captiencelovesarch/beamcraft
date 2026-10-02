package dev.captience.beamcraft;

import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockBehaviour;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * BeamCraft: Minecraft runs hidden as the player's brain while BeamNG.drive renders
 * the world. The common half: terrain collision, block tracking, world rules.
 */
public class BeamCraft implements ModInitializer {
	public static final String MOD_ID = "beamcraft";
	public static final Logger LOG = LoggerFactory.getLogger("BeamCraft");

	public static final Block GROUND_ANCHOR = Blocks.register(
		ResourceKey.create(Registries.BLOCK, Identifier.fromNamespaceAndPath(MOD_ID, "ground")),
		GroundAnchorBlock::new,
		BlockBehaviour.Properties.of().strength(-1.0F, 3600000.0F).noLootTable().noOcclusion().noCollision());

	private int saveTimer;

	@Override
	public void onInitialize() {
		ServerLifecycleEvents.SERVER_STARTED.register(server -> {
			BlockSync.onServerStarted(server);
			applyWorldRules(server);
		});
		ServerLifecycleEvents.SERVER_STOPPING.register(BlockSync::onServerStopping);
		ServerTickEvents.END_SERVER_TICK.register(server -> {
			if (++saveTimer >= 200) {
				saveTimer = 0;
				BlockSync.saveIndex(server);
			}
		});
	}

	/** BeamNG owns time, weather and the scenery; Minecraft only runs the player. */
	private static void applyWorldRules(MinecraftServer server) {
		String[] commands = {
			"gamerule advance_time false",
			"gamerule advance_weather false",
			"gamerule spawn_mobs false",
			"gamerule spawn_monsters false",
			"gamerule spawn_patrols false",
			"gamerule spawn_phantoms false",
			"gamerule spawn_wandering_traders false",
			"gamerule player_movement_check false",
			"gamerule elytra_movement_check false",
			"gamerule immediate_respawn true",
			"gamerule send_command_feedback false",
			"gamerule show_advancement_messages false",
			"time set noon",
			"weather clear",
		};
		for (String c : commands) {
			try {
				server.getCommands().performPrefixedCommand(server.createCommandSourceStack().withSuppressedOutput(), c);
			} catch (RuntimeException e) {
				LOG.warn("World rule '{}' failed: {}", c, e.getMessage());
			}
		}
	}
}
