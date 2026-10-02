package dev.captience.beamcraft;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import net.minecraft.core.BlockPos;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.storage.LevelResource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Server-side view of which blocks BeamNG needs to know about.
 *
 * Every block change in the overworld is queued as (x, y, z, stateId) for the client
 * thread to forward. A persistent index of chunks that have ever held a block lets a
 * fresh BeamNG connection receive the whole build, including far-away chunks that
 * aren't loaded around the player.
 */
public final class BlockSync {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/BlockSync");
	private static final String INDEX_FILE = "beamcraft_chunks.txt";

	/** Pending changes: int[]{x, y, z, stateId}. */
	public static final ConcurrentLinkedQueue<int[]> CHANGES = new ConcurrentLinkedQueue<>();
	private static final Set<Long> CHUNK_INDEX = ConcurrentHashMap.newKeySet();
	private static volatile boolean indexDirty;
	private static volatile MinecraftServer server;

	private BlockSync() {}

	public static void onServerStarted(MinecraftServer s) {
		server = s;
		CHUNK_INDEX.clear();
		CHANGES.clear();
		Path p = indexPath(s);
		try {
			if (Files.exists(p)) {
				for (String line : Files.readAllLines(p, StandardCharsets.UTF_8)) {
					line = line.trim();
					if (!line.isEmpty()) CHUNK_INDEX.add(Long.parseLong(line));
				}
			}
		} catch (IOException | NumberFormatException e) {
			LOG.warn("Could not read chunk index", e);
		}
		LOG.info("Chunk index: {} chunk(s) with blocks", CHUNK_INDEX.size());
	}

	public static void onServerStopping(MinecraftServer s) {
		saveIndex(s);
		server = null;
		CHANGES.clear();
	}

	public static void saveIndex(MinecraftServer s) {
		if (!indexDirty) return;
		indexDirty = false;
		StringBuilder sb = new StringBuilder();
		for (Long k : CHUNK_INDEX) sb.append(k).append('\n');
		try {
			Files.writeString(indexPath(s), sb.toString(), StandardCharsets.UTF_8);
		} catch (IOException e) {
			LOG.warn("Could not save chunk index", e);
		}
	}

	private static Path indexPath(MinecraftServer s) {
		return s.getWorldPath(LevelResource.ROOT).resolve(INDEX_FILE);
	}

	/** Called for every block update the server sends to clients. */
	public static void onBlockUpdated(ServerLevel level, BlockPos pos, BlockState state) {
		if (level.dimension() != Level.OVERWORLD) return;
		CHANGES.add(new int[] {pos.getX(), pos.getY(), pos.getZ(), Block.getId(state)});
		if (!state.isAir() && CHUNK_INDEX.add(ChunkPos.pack(pos.getX() >> 4, pos.getZ() >> 4))) {
			indexDirty = true;
		}
	}

	/** Queue every block of every indexed chunk. Runs on the server thread. */
	public static void requestFullSync() {
		MinecraftServer s = server;
		if (s == null) return;
		s.execute(() -> {
			ServerLevel level = s.overworld();
			int blocks = 0;
			List<Long> empty = new ArrayList<>();
			for (Long key : CHUNK_INDEX) {
				int cx = ChunkPos.getX(key), cz = ChunkPos.getZ(key);
				LevelChunk chunk = level.getChunk(cx, cz);
				int found = 0;
				LevelChunkSection[] sections = chunk.getSections();
				for (int si = 0; si < sections.length; si++) {
					LevelChunkSection section = sections[si];
					if (section.hasOnlyAir()) continue;
					int baseY = level.getSectionYFromSectionIndex(si) << 4;
					for (int y = 0; y < 16; y++) {
						for (int z = 0; z < 16; z++) {
							for (int x = 0; x < 16; x++) {
								BlockState st = section.getBlockState(x, y, z);
								if (st.isAir()) continue;
								CHANGES.add(new int[] {(cx << 4) + x, baseY + y, (cz << 4) + z, Block.getId(st)});
								found++;
							}
						}
					}
				}
				if (found == 0) empty.add(key);
				blocks += found;
			}
			if (!empty.isEmpty()) {
				CHUNK_INDEX.removeAll(empty);
				indexDirty = true;
			}
			LOG.info("Full sync: {} block(s) in {} chunk(s)", blocks, CHUNK_INDEX.size());
		});
	}
}
